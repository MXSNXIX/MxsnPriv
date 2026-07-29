#if UNITY_EDITOR
using System.IO;
using UnityEditor;
using UnityEngine;

namespace Poi.Tools
{
    public static class PoiColorAdjustBaker
    {
        static Shader _bakerShader;

        static Shader BakerShader
        {
            get
            {
                if (_bakerShader == null)
                    _bakerShader = Shader.Find("Hidden/Poi/ColorAdjustBaker");
                return _bakerShader;
            }
        }

        /// <summary>
        /// Checks whether any color adjust properties have been changed from their defaults.
        /// </summary>
        public static bool HasColorAdjustChanges(Material material)
        {
            if (!material.HasProperty("_MainColorAdjustToggle"))
                return false;
            if (material.GetFloat("_MainColorAdjustToggle") == 0)
                return false;

            bool hueShiftActive = material.GetFloat("_MainHueShiftToggle") == 1 &&
                                  material.GetFloat("_MainHueShift") != 0;
            bool satChanged = material.GetFloat("_Saturation") != 0;
            bool brightChanged = material.GetFloat("_MainBrightness") != 0;
            bool gammaChanged = Mathf.Abs(material.GetFloat("_MainGamma") - 1f) > 0.001f;
            bool chromatizeChanged = material.GetFloat("_MainChromatize") != 0;
            bool tintActive = material.GetColor("_MainTintColor").a > 0;
            bool gradationActive = material.HasProperty("_ColorGradingToggle") &&
                                   material.GetFloat("_ColorGradingToggle") > 0 &&
                                   material.GetFloat("_MainGradationStrength") > 0;

            return hueShiftActive || satChanged || brightChanged || gammaChanged ||
                   chromatizeChanged || tintActive || gradationActive;
        }

        /// <summary>
        /// Bakes the current color adjust settings into the main texture.
        /// Saves a new PNG next to the original and resets color adjust properties.
        /// </summary>
        public static void BakeColorAdjust(Material material)
        {
            if (BakerShader == null)
            {
                EditorUtility.DisplayDialog("Bake Error",
                    "Could not find baker shader (Hidden/Poi/ColorAdjustBaker). Make sure it exists in Resources.",
                    "OK");
                return;
            }

            Texture mainTex = material.GetTexture("_MainTex");
            if (mainTex == null)
            {
                EditorUtility.DisplayDialog("Bake Error",
                    "No main texture assigned. Please assign a main texture before baking.",
                    "OK");
                return;
            }

            if (!HasColorAdjustChanges(material))
            {
                EditorUtility.DisplayDialog("Nothing to Bake",
                    "Color adjust properties are all at their default values. Nothing to bake.",
                    "OK");
                return;
            }

            if (!EditorUtility.DisplayDialog("Bake Color Adjust",
                "This will bake the current color adjustments into a new texture and reset the color adjust settings.\n\n" +
                "The original texture will not be modified.",
                "Bake", "Cancel"))
                return;

            Undo.RecordObject(material, "Bake Color Adjust");

            // Load the source texture with full read access
            string srcPath = AssetDatabase.GetAssetPath(mainTex);
            Texture2D srcTexture = LoadReadableTexture(srcPath);
            if (srcTexture == null)
            {
                // Fallback: use the texture as-is
                srcTexture = mainTex as Texture2D;
                if (srcTexture == null)
                {
                    EditorUtility.DisplayDialog("Bake Error",
                        "Could not load the main texture for baking.",
                        "OK");
                    return;
                }
            }

            // Set up baker material
            var bakerMat = new Material(BakerShader);
            SetBakerProperties(bakerMat, material, srcTexture);

            // Blit
            int width = srcTexture.width;
            int height = srcTexture.height;
            Texture2D outTexture = new Texture2D(width, height, TextureFormat.RGBA32, false);

            RenderTexture prevRT = RenderTexture.active;
            RenderTexture rt = RenderTexture.GetTemporary(width, height, 0, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB);
            Graphics.Blit(srcTexture, rt, bakerMat);
            RenderTexture.active = rt;
            outTexture.ReadPixels(new Rect(0, 0, width, height), 0, 0);
            outTexture.Apply();
            RenderTexture.active = prevRT;
            RenderTexture.ReleaseTemporary(rt);

            // Save the baked texture
            string savedPath = SaveBakedTexture(outTexture, srcPath, material.name);
            if (string.IsNullOrEmpty(savedPath))
            {
                Object.DestroyImmediate(bakerMat);
                Object.DestroyImmediate(outTexture);
                return;
            }

            // Copy import settings from original
            CopyTextureImportSettings(srcPath, savedPath);

            // Load the saved texture asset
            Texture2D savedTexture = AssetDatabase.LoadAssetAtPath<Texture2D>(savedPath);

            // Assign new texture and reset color adjust properties
            material.SetTexture("_MainTex", savedTexture);
            ResetColorAdjustProperties(material);

            // Cleanup
            Object.DestroyImmediate(bakerMat);
            Object.DestroyImmediate(outTexture);

            EditorGUIUtility.PingObject(savedTexture);
            Debug.Log($"<color=blue>Poi:</color> Baked color adjust to: {savedPath}");
        }

        static void SetBakerProperties(Material baker, Material source, Texture2D srcTex)
        {
            baker.SetTexture("_MainTex", srcTex);

            // Color adjust mask
            if (source.HasProperty("_MainColorAdjustTexture"))
            {
                Texture mask = source.GetTexture("_MainColorAdjustTexture");
                if (mask != null)
                {
                    string maskPath = AssetDatabase.GetAssetPath(mask);
                    Texture2D readableMask = LoadReadableTexture(maskPath);
                    baker.SetTexture("_MainColorAdjustTexture", readableMask != null ? readableMask : mask);
                }
                CopyTextureSTIfExists(baker, source, "_MainColorAdjustTexture");
            }

            // Gradation map
            if (source.HasProperty("_MainGradationTex"))
            {
                Texture grad = source.GetTexture("_MainGradationTex");
                if (grad != null)
                    baker.SetTexture("_MainGradationTex", grad);
            }

            // Tint texture
            if (source.HasProperty("_MainTintTexture"))
            {
                Texture tint = source.GetTexture("_MainTintTexture");
                if (tint != null)
                    baker.SetTexture("_MainTintTexture", tint);
                CopyTextureSTIfExists(baker, source, "_MainTintTexture");
            }

            // Float properties
            SetFloatIfExists(baker, source, "_MainHueShiftToggle");
            SetFloatIfExists(baker, source, "_MainHueShift");
            SetFloatIfExists(baker, source, "_MainHueShiftColorSpace");
            SetFloatIfExists(baker, source, "_MainHueShiftSelectOrShift");
            SetFloatIfExists(baker, source, "_MainHueShiftReplace");
            SetFloatIfExists(baker, source, "_Saturation");
            SetFloatIfExists(baker, source, "_MainChromatize");
            SetFloatIfExists(baker, source, "_MainBrightness");
            SetFloatIfExists(baker, source, "_MainGamma");
            SetFloatIfExists(baker, source, "_ColorGradingToggle");
            SetFloatIfExists(baker, source, "_MainGradationStrength");

            // Color properties
            if (source.HasProperty("_MainTintColor"))
                baker.SetColor("_MainTintColor", source.GetColor("_MainTintColor"));
        }

        static void SetFloatIfExists(Material baker, Material source, string prop)
        {
            if (source.HasProperty(prop))
                baker.SetFloat(prop, source.GetFloat(prop));
        }

        static void CopyTextureSTIfExists(Material baker, Material source, string texProp)
        {
            baker.SetTextureScale(texProp, source.GetTextureScale(texProp));
            baker.SetTextureOffset(texProp, source.GetTextureOffset(texProp));
        }

        static void ResetColorAdjustProperties(Material material)
        {
            // Disable the section toggle and keyword
            if (material.HasProperty("_MainColorAdjustToggle"))
                material.SetFloat("_MainColorAdjustToggle", 0);
            material.DisableKeyword("COLOR_GRADING_HDR");

            if (material.HasProperty("_MainHueShiftToggle"))
                material.SetFloat("_MainHueShiftToggle", 0);
            if (material.HasProperty("_MainHueShift"))
                material.SetFloat("_MainHueShift", 0);
            if (material.HasProperty("_MainHueShiftSpeed"))
                material.SetFloat("_MainHueShiftSpeed", 0);
            if (material.HasProperty("_Saturation"))
                material.SetFloat("_Saturation", 0);
            if (material.HasProperty("_MainChromatize"))
                material.SetFloat("_MainChromatize", 0);
            if (material.HasProperty("_MainBrightness"))
                material.SetFloat("_MainBrightness", 0);
            if (material.HasProperty("_MainGamma"))
                material.SetFloat("_MainGamma", 1);
            if (material.HasProperty("_MainTintColor"))
                material.SetColor("_MainTintColor", new Color(1, 1, 1, 0));
            if (material.HasProperty("_MainGradationStrength"))
                material.SetFloat("_MainGradationStrength", 0);
            if (material.HasProperty("_ColorGradingToggle"))
                material.SetFloat("_ColorGradingToggle", 0);
        }

        static Texture2D LoadReadableTexture(string assetPath)
        {
            if (string.IsNullOrEmpty(assetPath))
                return null;

            string fullPath = Path.GetFullPath(assetPath);
            if (!File.Exists(fullPath))
                return null;

            byte[] fileData = File.ReadAllBytes(fullPath);
            Texture2D tex = new Texture2D(2, 2, TextureFormat.RGBA32, false);
            if (tex.LoadImage(fileData))
                return tex;

            Object.DestroyImmediate(tex);
            return null;
        }

        static string SaveBakedTexture(Texture2D texture, string originalPath, string materialName)
        {
            string directory = Path.GetDirectoryName(originalPath);
            string originalName = Path.GetFileNameWithoutExtension(originalPath);
            string newName = $"{originalName}_baked";

            string savePath = Path.Combine(directory, newName + ".png").Replace('\\', '/');
            savePath = AssetDatabase.GenerateUniqueAssetPath(savePath);

            byte[] pngData = texture.EncodeToPNG();
            if (pngData == null)
            {
                EditorUtility.DisplayDialog("Bake Error", "Failed to encode baked texture to PNG.", "OK");
                return null;
            }

            File.WriteAllBytes(savePath, pngData);
            AssetDatabase.ImportAsset(savePath);
            return savePath;
        }

        static void CopyTextureImportSettings(string fromPath, string toPath)
        {
            var fromImporter = AssetImporter.GetAtPath(fromPath) as TextureImporter;
            var toImporter = AssetImporter.GetAtPath(toPath) as TextureImporter;

            if (fromImporter == null || toImporter == null)
                return;

            var settings = new TextureImporterSettings();
            fromImporter.ReadTextureSettings(settings);
            toImporter.SetTextureSettings(settings);
            toImporter.SetPlatformTextureSettings(fromImporter.GetDefaultPlatformTextureSettings());
            AssetDatabase.ImportAsset(toPath);
        }
    }
}
#endif

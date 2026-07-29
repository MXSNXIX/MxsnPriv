Shader "Hidden/Poi/ColorAdjustBaker"
{
    Properties
    {
        _MainTex ("Main Texture", 2D) = "white" {}
        _MainColorAdjustTexture ("Color Adjust Mask", 2D) = "white" {}
        _MainGradationTex ("Gradation Map", 2D) = "white" {}
        _MainTintTexture ("Tint Texture", 2D) = "white" {}

        // Color adjust parameters
        _MainHueShiftToggle ("Hue Shift Toggle", Float) = 0
        _MainHueShift ("Hue Shift", Float) = 0
        _MainHueShiftColorSpace ("Color Space", Float) = 0
        _MainHueShiftSelectOrShift ("Select or Shift", Float) = 1
        _MainHueShiftReplace ("Hue Replace", Float) = 1
        _Saturation ("Saturation", Float) = 0
        _MainChromatize ("Chromatize", Float) = 0
        _MainBrightness ("Brightness", Float) = 0
        _MainGamma ("Gamma", Float) = 1

        // Tint
        _MainTintColor ("Tint Color", Color) = (1, 1, 1, 0)

        // Gradation
        _ColorGradingToggle ("Color Grading Toggle", Float) = 0
        _MainGradationStrength ("Gradation Strength", Float) = 0
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" }
        LOD 100

        Pass
        {
            Cull Off
            ZWrite Off
            ZTest Always

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "UnityCG.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float4 vertex : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            sampler2D _MainTex;
            float4 _MainTex_ST;
            sampler2D _MainColorAdjustTexture;
            float4 _MainColorAdjustTexture_ST;
            sampler2D _MainGradationTex;
            sampler2D _MainTintTexture;
            float4 _MainTintTexture_ST;

            float _MainHueShiftToggle;
            float _MainHueShift;
            float _MainHueShiftColorSpace;
            float _MainHueShiftSelectOrShift;
            float _MainHueShiftReplace;
            float _Saturation;
            float _MainChromatize;
            float _MainBrightness;
            float _MainGamma;
            float4 _MainTintColor;
            float _ColorGradingToggle;
            float _MainGradationStrength;

            // ---- Color space conversions ----

            float3 RGBtoHSV(float3 c)
            {
                float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
                float4 p = lerp(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
                float4 q = lerp(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
                float d = q.x - min(q.w, q.y);
                float e = 1.0e-10;
                return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
            }

            float3 HSVtoRGB(float3 c)
            {
                float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
                float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
                return c.z * lerp(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
            }

            float3 linear_srgb_to_oklab(float3 c)
            {
                float l = 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z;
                float m = 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z;
                float s = 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z;
                float l_ = pow(max(l, 0.0), 1.0 / 3.0);
                float m_ = pow(max(m, 0.0), 1.0 / 3.0);
                float s_ = pow(max(s, 0.0), 1.0 / 3.0);
                return float3(
                    0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                    1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                    0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
                );
            }

            float3 oklab_to_linear_srgb(float3 c)
            {
                float l_ = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
                float m_ = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
                float s_ = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
                float l = l_ * l_ * l_;
                float m = m_ * m_ * m_;
                float s = s_ * s_ * s_;
                return float3(
                    + 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                    - 1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                    - 0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
                );
            }

            // sRGB <-> Linear
            float3 SRGBToLinear(float3 c)
            {
                return pow(max(c, 0.0), 2.2);
            }

            float3 LinearToSRGB(float3 c)
            {
                return pow(max(c, 0.0), 1.0 / 2.2);
            }

            // ---- Hue shift functions ----

            float3 hueShiftOKLab(float3 color, float shift, float selectOrShift)
            {
                float3 oklab = linear_srgb_to_oklab(color);
                float chroma = length(oklab.yz);
                oklab.y = selectOrShift > 0.5 ? oklab.y : chroma;
                oklab.z = selectOrShift > 0.5 ? oklab.z : 0;
                float sn, cs;
                sincos(shift * 6.28318530718, sn, cs);
                oklab.yz = float2(cs * oklab.y - sn * oklab.z, sn * oklab.y + cs * oklab.z);
                return oklab_to_linear_srgb(oklab);
            }

            float3 hueShiftHSV(float3 color, float hueOffset, float selectOrShift)
            {
                float3 hsvCol = RGBtoHSV(color);
                hsvCol.x = hsvCol.x * selectOrShift + hueOffset;
                return HSVtoRGB(hsvCol);
            }

            float3 hueShift(float3 color, float shift, float colorSpace, float selectOrShift)
            {
                float3 oklab = hueShiftOKLab(color, shift, selectOrShift);
                float3 hsv = hueShiftHSV(color, shift, selectOrShift);
                float w = saturate(colorSpace);
                return lerp(oklab, hsv, w);
            }

            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;
                return o;
            }

            float4 frag(v2f i) : SV_Target
            {
                float4 col = tex2D(_MainTex, i.uv);
                float2 maskUV = i.uv * _MainColorAdjustTexture_ST.xy + _MainColorAdjustTexture_ST.zw;
                float4 hueShiftAlpha = tex2D(_MainColorAdjustTexture, maskUV);

                // Work in linear space for consistency
                #if !defined(UNITY_COLORSPACE_GAMMA)
                    float3 baseColor = col.rgb;
                #else
                    float3 baseColor = SRGBToLinear(col.rgb);
                #endif

                // Hue Shift
                if (_MainHueShiftToggle == 1)
                {
                    float shift = _MainHueShift;
                    if (_MainHueShiftReplace)
                    {
                        baseColor = lerp(baseColor, hueShift(baseColor, shift, _MainHueShiftColorSpace, _MainHueShiftSelectOrShift), hueShiftAlpha.r);
                    }
                    else
                    {
                        baseColor = hueShift(baseColor, frac((shift - (1 - hueShiftAlpha.r))), _MainHueShiftColorSpace, _MainHueShiftSelectOrShift);
                    }
                }

                // Gradation Map
                if (_MainGradationStrength > 0 && _ColorGradingToggle > 0)
                {
                    float3 tempColor = LinearToSRGB(baseColor);
                    tempColor.r = tex2D(_MainGradationTex, float2(tempColor.r, 0.5)).r;
                    tempColor.g = tex2D(_MainGradationTex, float2(tempColor.g, 0.5)).g;
                    tempColor.b = tex2D(_MainGradationTex, float2(tempColor.b, 0.5)).b;
                    tempColor = SRGBToLinear(tempColor);
                    baseColor = lerp(baseColor, tempColor, _MainGradationStrength);
                }

                // Gamma
                baseColor = lerp(baseColor, pow(abs(baseColor), _MainGamma), hueShiftAlpha.a);

                // Saturation
                baseColor = lerp(baseColor, dot(baseColor, float3(0.3, 0.59, 0.11)), -_Saturation * hueShiftAlpha.b);

                // Chromatize
                if (_MainChromatize != 0)
                {
                    float minRgb = min(baseColor.r, min(baseColor.g, baseColor.b));
                    float maxRgb = max(baseColor.r, max(baseColor.g, baseColor.b));
                    float rangeRgb = maxRgb - minRgb;

                    float3 saturatedRef = (rangeRgb > 0.0001) ? (baseColor - minRgb) / rangeRgb : float3(1, 0, 0);
                    float3 saturatedOklab = linear_srgb_to_oklab(saturatedRef);
                    float maxChroma = length(saturatedOklab.yz);

                    float3 oklab = linear_srgb_to_oklab(baseColor);
                    float chroma = length(oklab.yz);
                    float hue = atan2(oklab.z, oklab.y);

                    chroma = min(chroma * (1.0 + _MainChromatize), maxChroma);

                    oklab.y = chroma * cos(hue);
                    oklab.z = chroma * sin(hue);
                    baseColor = saturate(oklab_to_linear_srgb(oklab));
                }

                // Tint
                if (_MainTintColor.a > 0)
                {
                    float2 tintUV = i.uv * _MainTintTexture_ST.xy + _MainTintTexture_ST.zw;
                    float4 mainTintTexSample = tex2D(_MainTintTexture, tintUV);
                    float3 finalTintColor = _MainTintColor.rgb * mainTintTexSample.rgb;
                    float finalTintAlpha = _MainTintColor.a * mainTintTexSample.a;

                    #if !defined(UNITY_COLORSPACE_GAMMA)
                        float3 tintColorLinear = finalTintColor;
                    #else
                        float3 tintColorLinear = SRGBToLinear(finalTintColor);
                    #endif

                    float3 tintOklab = linear_srgb_to_oklab(tintColorLinear);
                    float tintHue = atan2(tintOklab.z, tintOklab.y);
                    float tintMin = min(tintColorLinear.r, min(tintColorLinear.g, tintColorLinear.b));
                    float tintMax = max(tintColorLinear.r, max(tintColorLinear.g, tintColorLinear.b));
                    float tintSatFactor = (tintMax > 0.0001) ? 1.0 - (tintMin / tintMax) : 0;

                    float3 inputOklab = linear_srgb_to_oklab(baseColor);
                    float inputL = inputOklab.x;
                    float inputChroma = length(inputOklab.yz);

                    float newChroma = inputChroma * tintSatFactor;
                    float3 tintedOklab = float3(inputL, newChroma * cos(tintHue), newChroma * sin(tintHue));
                    float3 tintedLinear = saturate(oklab_to_linear_srgb(tintedOklab));

                    baseColor = lerp(baseColor, tintedLinear, finalTintAlpha);
                }

                // Brightness
                baseColor = saturate(lerp(baseColor, baseColor * (_MainBrightness + 1), hueShiftAlpha.g));

                // Convert back
                #if !defined(UNITY_COLORSPACE_GAMMA)
                    col.rgb = baseColor;
                #else
                    col.rgb = LinearToSRGB(baseColor);
                #endif

                return col;
            }
            ENDCG
        }
    }
}

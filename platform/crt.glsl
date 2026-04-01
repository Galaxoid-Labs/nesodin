#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec2 resolution;

out vec4 finalColor;

void main()
{
    vec2 uv = fragTexCoord;

    // Slight barrel distortion (CRT curvature)
    vec2 centered = uv * 2.0 - 1.0;
    float barrel = dot(centered, centered) * 0.06;
    uv = (centered * (1.0 + barrel)) * 0.5 + 0.5;

    // Black outside the curved screen area
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        finalColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    vec3 color = texture(texture0, uv).rgb;

    // Scanlines — darken every other row
    float scanline = sin(uv.y * resolution.y * 3.14159) * 0.5 + 0.5;
    scanline = mix(0.75, 1.0, scanline);
    color *= scanline;

    // Subtle RGB shadow mask (vertical stripes)
    float mask = mod(gl_FragCoord.x, 3.0);
    if (mask < 1.0)      color *= vec3(1.0, 0.85, 0.85);
    else if (mask < 2.0) color *= vec3(0.85, 1.0, 0.85);
    else                 color *= vec3(0.85, 0.85, 1.0);

    // Vignette — darken edges
    vec2 vig = uv * (1.0 - uv);
    float vignette = vig.x * vig.y * 15.0;
    vignette = clamp(pow(vignette, 0.25), 0.0, 1.0);
    color *= vignette;

    // Slight brightness boost to compensate for darkening
    color *= 1.2;

    finalColor = vec4(color, 1.0);
}

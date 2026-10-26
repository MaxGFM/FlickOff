#version 100
precision mediump float;

varying vec3 fragNormal;
varying vec3 fragPos;

uniform vec3 sunDir1;
uniform vec3 sunColor1;
uniform vec3 sunDir2;
uniform vec3 sunColor2;
uniform vec3 ambientColor;
uniform vec4 colDiffuse;

void main() {
    vec3 n = normalize(fragNormal);
    float diff1 = max(dot(n, -normalize(sunDir1)), 0.0);
    float diff2 = max(dot(n, -normalize(sunDir2)), 0.0);
    vec3 lit = ambientColor + sunColor1 * diff1 + sunColor2 * diff2;
    gl_FragColor = vec4(lit * colDiffuse.rgb, colDiffuse.a);
}
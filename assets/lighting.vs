#version 100

attribute vec3 vertexPosition;
attribute vec3 vertexNormal;

uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 matNormal;

varying vec3 fragNormal;
varying vec3 fragPos;

void main() {
    fragNormal = (matNormal * vec4(vertexNormal, 0.0)).xyz;
    fragPos = (matModel * vec4(vertexPosition, 1.0)).xyz;
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
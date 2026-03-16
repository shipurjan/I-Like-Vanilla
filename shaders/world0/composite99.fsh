#version 140

uniform sampler2D colortex9;
uniform sampler2D shadowtex0;

void main() {
	vec3 color = texelFetch(colortex9, ivec2(gl_FragCoord.xy), 0).rgb;
	// DEBUG: red bar to confirm this branch is loaded — REMOVE ME
	if (gl_FragCoord.x < 200.0 && gl_FragCoord.y > 0.0 && gl_FragCoord.y < 40.0) color = vec3(1.0, 0.0, 0.0);
	/* DRAWBUFFERS:0 */
	gl_FragData[0] = vec4(color, 1.0);
}

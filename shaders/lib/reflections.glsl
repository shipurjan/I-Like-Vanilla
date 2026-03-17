void raytrace(out vec2 reflectionPos, out int error, out float convergenceStepZ, vec3 viewPos, vec3 reflectionDir, vec3 normal) {

	// basic setup
	vec3 screenPos = mult(gbufferProjection, viewPos) * 0.5 + 0.5;
	vec3 nextScreenPos = mult(gbufferProjection, viewPos - reflectionDir * pow(dot(viewPos, viewPos), 0.3)) * 0.5 + 0.5; // normally this would be pos+dir (and step=next-pos), but for some reason it works better this way

	// calculate the optimal stepVector that will stop at the screen edge
	vec3 stepVector = screenPos - nextScreenPos;
	stepVector /= length(stepVector.xy);
	if (abs(stepVector.x) > 0.0001) {
		float clampedStepX = clamp(stepVector.x, -screenPos.x, 1.0 - screenPos.x);
		stepVector.yz *= clampedStepX / stepVector.x;
		stepVector.x = clampedStepX;
	}
	if (abs(stepVector.y) > 0.0001) {
		float clampedStepY = clamp(stepVector.y, -screenPos.y, 1.0 - screenPos.y);
		stepVector.xz *= clampedStepY / stepVector.y;
		stepVector.y = clampedStepY;
	}
	stepVector /= (REFLECTION_ITERATIONS - 8); // ensure that the ray will reach the edge of the screen 8 steps early, allows for fine-tuning to not be cut short

	float dither = bayer64(gl_FragCoord.xy);
	#if TEMPORAL_FILTER_ENABLED == 1
		dither = fract(dither + 1.61803398875 * mod(float(frameCounter), 3600.0));
	#endif
	screenPos += stepVector * (dither + length(viewPos) / 1024) * REFLECTION_DITHER_AMOUNT;

	float originDistSq = dot(viewPos, viewPos);
	convergenceStepZ = stepVector.z;
	int hitCount = 0;
	for (int i = 0; i < REFLECTION_ITERATIONS; i++) {

		float realDepth = texture2D(DEPTH_BUFFER_WO_TRANS_OR_HANDHELD, screenPos.xy).r;
		#ifdef DISTANT_HORIZONS
			vec3 realBlockViewPos = screenToView(vec3(screenPos.xy, realDepth));
			float realDepthDh = texture2D(DH_DEPTH_BUFFER_WO_TRANS, screenPos.xy).r;
			vec3 realBlockViewPosDh = screenToViewDh(vec3(screenPos.xy, realDepthDh));
			if (realBlockViewPosDh.z > realBlockViewPos.z) realBlockViewPos = realBlockViewPosDh;
			vec4 sampleScreenPos = gbufferProjection * vec4(realBlockViewPos, 1.0);
			realDepth = sampleScreenPos.z / sampleScreenPos.w * 0.5 + 0.5;
		#endif
		float realToScreen = screenPos.z - realDepth;

		if (realToScreen > 0.0 && realToScreen < sqrt(stepVector.z) * 0.5) {
			// Reject hits on geometry much closer than the reflecting surface
			vec3 hitViewPos = screenToView(vec3(screenPos.xy, realDepth));
			if (dot(hitViewPos, hitViewPos) < originDistSq * 0.04) {
				screenPos += stepVector;
			} else {
				// Reject hits that deviate from the true 3D reflection ray
				vec3 toHit = hitViewPos - viewPos;
				float alongRay = dot(toHit, reflectionDir);
				vec3 perpToRay = toHit - reflectionDir * alongRay;
				if (alongRay < 0.0 || dot(perpToRay, perpToRay) > 4.0) {
					screenPos += stepVector;
				} else {
					hitCount ++;
					if (hitCount >= 5) { // converged on point
						reflectionPos = screenPos.xy;
						error = 0;
						float depthWithHandheld = texture2D(DEPTH_BUFFER_ALL, screenPos.xy).r;
						if (depthIsHand(depthWithHandheld) && originDistSq > 2.5 + dither) error = 1;
						return;
					}
					screenPos -= stepVector;
					stepVector *= 0.5;
				}
			}
		} else {
			screenPos += stepVector;
		}
	}

	error = 1;
}



void addReflection(inout vec3 color, vec3 viewPos, vec3 normal, vec2 lmcoord, sampler2D texture, float reflectionStrength) {

	vec3 reflectionDirection = reflect(normalize(viewPos), normalize(normal));
	vec2 reflectionPos;
	int error;
	float convergenceStepZ;
	raytrace(reflectionPos, error, convergenceStepZ, viewPos, reflectionDirection, normal);

	#if SSR_DEBUG >= 1
		if (error == 0) {
			#if SSR_DEBUG == 1
				color = vec3(1.0, 0.0, 0.0);
			#elif SSR_DEBUG == 2
				vec3 hitView = screenToView(vec3(reflectionPos, texture2D(DEPTH_BUFFER_WO_TRANS_OR_HANDHELD, reflectionPos).r));
				float ratio = dot(hitView, hitView) / dot(viewPos, viewPos);
				color = vec3(clamp(1.0 - ratio, 0.0, 1.0), clamp(ratio, 0.0, 1.0), 0.0);
			#elif SSR_DEBUG == 3
				// log scale of initial stepVector.z: green=large Z step, red=tiny Z step
				// -log2 maps: 1e-2→~7, 1e-4→~13, 1e-6→~20, 1e-8→~27
				float v = clamp((-log2(max(convergenceStepZ, 1e-20)) - 5.0) / 20.0, 0.0, 1.0);
				color = vec3(v, 1.0 - v, 0.0);
			#endif
		} else {
			color = vec3(0.0, 0.0, 0.3);
		}
		return;
	#endif

	float fresnel = 1.0 - abs(dot(normalize(viewPos), normal));
	fresnel *= fresnel;
	fresnel *= fresnel;
	reflectionStrength *= 1.0 - REFLECTION_FRESNEL * (1.0 - fresnel);
	vec3 skyColor = getSkyColor(reflectionDirection, true);
	float maxBrightness = max(lmcoord.x * 0.75, lmcoord.y);
	#ifdef END
		maxBrightness = 0.5 + 0.5 * lmcoord.x;
	#endif
	skyColor *= maxBrightness * maxBrightness;
	if (isEyeInWater == 1) {
		skyColor = 0.08 + 0.125 * skyColor;
		skyColor += vec3(0.0, 0.03, 0.3);
	}

	const float inputColorWeight = 0.2;

	vec3 reflectionColor;
	if (error == 0) {
		reflectionColor = texture2DLod(texture, reflectionPos, 0).rgb * 2.0;
		float fadeOutSlope = 1.0 / (max(normal.z, 0.0) + 0.0001);
		reflectionColor = mix(skyColor, reflectionColor, clamp(fadeOutSlope - fadeOutSlope * max(abs(reflectionPos.x * 2.0 - 1.0), abs(reflectionPos.y * 2.0 - 1.0)), 0.0, 1.0));
	} else {
		reflectionColor = skyColor;
	}
	reflectionColor *= (1.0 - inputColorWeight) + color * inputColorWeight;
	color = mix(color, reflectionColor, reflectionStrength);

}

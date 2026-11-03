// Based on https://gist.github.com/chardskarth/95874c54e29da6b5a36ab7b50ae2d088
float ease(float x) {
    return pow(1.0 - x, 10.0);
}

// Based on Inigo Quilez's 2D distance functions article: https://iquilezles.org/articles/distfunctions2d/
// Potencially optimized by eliminating conditionals and loops to enhance performance and reduce branching
float seg(in vec2 p, in vec2 a, in vec2 b, inout float s, float d) {
    vec2 e = b - a;
    vec2 w = p - a;
    // pq = p - proj with proj = a + e*t; writing w - e*t saves one vector add (IQ's original form).
    vec2 pq = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
    d = min(d, dot(pq, pq));

    float c0 = step(0.0, p.y - a.y);
    float c1 = 1.0 - step(0.0, p.y - b.y);
    float c2 = 1.0 - step(0.0, e.x * w.y - e.y * w.x);
    float allCond = c0 * c1 * c2;
    float noneCond = (1.0 - c0) * (1.0 - c1) * (1.0 - c2);
    float flip = mix(1.0, -1.0, step(0.5, allCond + noneCond));
    s *= flip;
    return d;
}

float getSdfParallelogram(in vec2 p, in vec2 v0, in vec2 v1, in vec2 v2, in vec2 v3) {
    float s = 1.0;
    float d = dot(p - v0, p - v0);

    d = seg(p, v0, v3, s, d);
    d = seg(p, v1, v0, s, d);
    d = seg(p, v2, v1, s, d);
    d = seg(p, v3, v2, s, d);

    return s * sqrt(d);
}

// Named norm, not normalize, so it doesn't shadow the GLSL built-in normalize (as in cursor_smear_rocket.glsl).
vec2 norm(vec2 value, float isPosition) {
    return (value * 2.0 - (iResolution.xy * isPosition)) / iResolution.y;
}

float blend(float t)
{
    float sqr = t * t;
    return sqr / (2.0 * (sqr - t) + 1.0);
}

float determineStartVertexFactor(vec2 a, vec2 b) {
    // Conditions using step
    float condition1 = step(b.x, a.x) * step(a.y, b.y); // a.x < b.x && a.y > b.y
    float condition2 = step(a.x, b.x) * step(b.y, a.y); // a.x > b.x && a.y < b.y

    // If neither condition is met, return 1 (else case)
    return 1.0 - max(condition1, condition2);
}
vec2 getRectangleCenter(vec4 rectangle) {
    return vec2(rectangle.x + (rectangle.z / 2.), rectangle.y - (rectangle.w / 2.));
}

const vec4 TRAIL_COLOR = vec4(1.0, 0.725, 0.161, 1.0); // yellow
const vec4 TRAIL_COLOR_ACCENT = vec4(1.0, 0., 0., 1.0); // red-orange
const float DURATION = .5;
// Don't draw trail within that distance * cursor size.
// This prevents trails from appearing when typing.
const float DRAW_THRESHOLD = 1.5;
// Don't draw trails within the same line: same line jumps are usually where
// people expect them.
const bool HIDE_TRAILS_ON_THE_SAME_LINE = false;
// Trail taper: width at the tail (previous cursor position) relative to the current cursor;
// 0.0 = tapers to a point, 1.0 = constant width. Mimics the rocket trail shape.
const float TAPER_FACTOR = 0.1;
// The red-orange halo 1 - smoothstep(sdf, -0.01, 0.001) weighs < 0.5/255 once sdf exceeds this (normalized units);
// used as the corridor-cull margin. Recompute it if the smoothstep constants below change.
const float GLOW_REACH = 0.42;

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    // Cache UV and sample the previous frame once to avoid repeated reads.
    vec2 uv = fragCoord.xy / iResolution.xy;
    fragColor = texture(iChannel0, uv);

    // Early exit 1: no trail when the window is unfocused or the cursor is hidden (as in cursor_balatro.glsl).
    // This also stops trails from cursor jumps while hidden (TUI redraws).
    if (iFocus == 0 || iCursorVisible == 0) {
        return;
    }

    // Early exit 2: nothing to draw once the animation is over. Compare raw time first: idle frames stop here, skipping blend/pow.
    // blend(t) < 1 for t < 1; if easedProgress underflows to 0 the trail is invisible, and this avoids divide-by-zero/NaN below.
    float t = (iTime - iTimeCursorChange) / DURATION;
    if (t >= 1.0) {
        return;
    }
    float easedProgress = ease(blend(max(t, 0.0)));
    if (easedProgress <= 0.0) {
        return;
    }

    //Normalization for cursor position and size;
    //cursor xy has the postion in a space of -1 to 1;
    //zw has the width and height
    vec4 currentCursor = vec4(norm(iCurrentCursor.xy, 1.), norm(iCurrentCursor.zw, 0.));
    vec4 previousCursor = vec4(norm(iPreviousCursor.xy, 1.), norm(iPreviousCursor.zw, 0.));

    // Early exit 3: no trail for tiny moves (typing). Compare squared distance first to avoid an expensive sqrt.
    vec2 centerCC = getRectangleCenter(currentCursor);
    vec2 centerCP = getRectangleCenter(previousCursor);
    vec2 delta = centerCC - centerCP;
    float lineLengthSq = dot(delta, delta);

    float cursorSize = max(currentCursor.z, currentCursor.w);
    float trailThreshold = DRAW_THRESHOLD * cursorSize;
    bool isOnSeparateLine = HIDE_TRAILS_ON_THE_SAME_LINE ? currentCursor.y != previousCursor.y : true;
    if (lineLengthSq <= trailThreshold * trailThreshold || !isOnSeparateLine) {
        return;
    }

    // Only compute sqrt when it is actually needed.
    float lineLength = sqrt(lineLengthSq);

    //Normalization for fragCoord to a space of -1 to 1;
    vec2 vu = norm(fragCoord, 1.);

    // Early exit 4: pixels beyond the current animation radius get no trail contribution, so skip the SDF.
    // Squared compare; sqrt and division are left for pixels that pass every cull.
    vec2 toEnd = vu - centerCC;
    float distSq = dot(toEnd, toEnd);
    float radius = lineLength * easedProgress;
    if (distSq >= radius * radius) {
        return;
    }

    // Early exit 5: corridor cull (cursor_balatro.glsl Stage 2). All quad vertices lie within reach of the two
    // cursor centers; padded by GLOW_REACH, so pixels outside the capsule are unchanged.
    vec2 fromPrev = vu - centerCP;
    vec2 off = fromPrev - delta * clamp(dot(fromPrev, delta) / lineLengthSq, 0.0, 1.0);
    float reach = (0.5 + TAPER_FACTOR) * length(max(currentCursor.zw, previousCursor.zw)) + GLOW_REACH;
    if (dot(off, off) > reach * reach) {
        return;
    }

    // Early exit 6: keep the cursor cell as-is (equivalent to the old step(sdfCursor, 0.0)), checked before any SDF.
    if (all(lessThanEqual(abs(toEnd), currentCursor.zw * 0.5))) {
        return;
    }

    float alphaModifier = sqrt(distSq) / radius;

    // Anti-aliasing edge width: equals norm(vec2(2.,2.),0.).x = 2.*2./iResolution.y,
    // computed once instead of per pixel inside smoothstep.
    float aaWidth = 4.0 / iResolution.y;

    //When drawing a parellelogram between cursors for the trail i need to determine where to start at the top-left or top-right vertex of the cursor
    float vertexFactor = determineStartVertexFactor(currentCursor.xy, previousCursor.xy);
    float invertedVertexFactor = 1.0 - vertexFactor;

    //Tapered trail: full width at the current cursor, narrowed by TAPER_FACTOR at the previous one,
    //giving a wide-head, narrow-tail rocket trail (as in cursor_smear_rocket.glsl).
    vec2 currentWidth = currentCursor.zw;
    vec2 previousWidth = currentCursor.zw * TAPER_FACTOR;

    //Set every vertex of my parellogram
    //v0, v1 = current cursor (full width); v2, v3 = previous cursor (narrowed)
    vec2 v0 = vec2(currentCursor.x + currentWidth.x * vertexFactor, currentCursor.y - currentWidth.y);
    vec2 v1 = vec2(currentCursor.x + currentWidth.x * invertedVertexFactor, currentCursor.y);
    vec2 v2 = vec2(previousCursor.x + previousWidth.x * invertedVertexFactor, previousCursor.y);
    vec2 v3 = vec2(previousCursor.x + previousWidth.x * vertexFactor, previousCursor.y - previousWidth.y);

    float sdfTrail = getSdfParallelogram(vu, v0, v1, v2, v3);

    vec4 newColor = fragColor;
    newColor = mix(newColor, TRAIL_COLOR_ACCENT, 1.0 - smoothstep(sdfTrail, -0.01, 0.001));
    newColor = mix(newColor, TRAIL_COLOR, 1.0 - smoothstep(0.0, aaWidth, sdfTrail));
    fragColor = mix(fragColor, newColor, 1.0 - alphaModifier);
}

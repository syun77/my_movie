#ifndef MV_SPINE_BRIDGE_H
#define MV_SPINE_BRIDGE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct MVSpine MVSpine;
typedef struct { float x, y, u, v, r, g, b, a; } MVSpineVertex;
typedef struct { int32_t page; uint32_t start, count; } MVSpineCommand;
MVSpine *mv_spine_create(const char *json, const char *atlas, char *error, int32_t errorCapacity);
void mv_spine_destroy(MVSpine *value);
int32_t mv_spine_page_count(MVSpine *value);
const char *mv_spine_page_name(MVSpine *value, int32_t page);
void mv_spine_page_info(MVSpine *value, int32_t page, int32_t *info);
int32_t mv_spine_animation_count(MVSpine *value);
const char *mv_spine_animation_name(MVSpine *value, int32_t index);
double mv_spine_animation_duration(MVSpine *value, int32_t index);
int32_t mv_spine_evaluate(MVSpine *value, const char *animation, double time, int32_t loop, char *error, int32_t errorCapacity);
const MVSpineVertex *mv_spine_vertices(MVSpine *value, int32_t *count);
const uint32_t *mv_spine_indices(MVSpine *value, int32_t *count);
const MVSpineCommand *mv_spine_commands(MVSpine *value, int32_t *count);
void mv_spine_bounds(MVSpine *value, float *bounds);
#ifdef __cplusplus
}
#endif
#endif

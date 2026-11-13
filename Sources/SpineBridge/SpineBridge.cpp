#include "SpineBridge.h"
#include <spine/spine.h>
#include <spine/SkeletonRenderer.h>
#include <memory>
#include <vector>
#include <stdexcept>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>

namespace spine { SpineExtension *getDefaultExtension() { return new DefaultSpineExtension(); } }
// Spine's default extension initializes process-wide state lazily.
static std::mutex runtimeMutex;
struct PageLoader : spine::TextureLoader {
    int next = 1;
    void load(spine::AtlasPage &page, const spine::String &) override { page.texture = reinterpret_cast<void *>(intptr_t(next++)); }
    void unload(void *) override {}
};
struct MVSpine {
    PageLoader loader;
    std::unique_ptr<spine::Atlas> atlas;
    std::unique_ptr<spine::SkeletonData> data;
    std::unique_ptr<spine::Skeleton> skeleton;
    spine::SkeletonRenderer renderer;
    std::vector<MVSpineVertex> vertices;
    std::vector<uint32_t> indices;
    std::vector<MVSpineCommand> commands;
    float bounds[4] = {};
};
static void failure(char *out, int32_t capacity, const char *message) { if (out && capacity > 0) std::snprintf(out, capacity, "%s", message); }
extern "C" MVSpine *mv_spine_create(const char *json, const char *atlas, char *error, int32_t capacity) {
    std::lock_guard<std::mutex> lock(runtimeMutex);
    try {
        auto value = std::make_unique<MVSpine>();
        value->atlas = std::make_unique<spine::Atlas>(atlas, int(std::strlen(atlas)), "", &value->loader);
        if (!value->atlas->getPages().size()) throw std::runtime_error("Atlas has no pages");
        spine::SkeletonJson parser(*value->atlas);
        value->data.reset(parser.readSkeletonData(json));
        if (!value->data) throw std::runtime_error(parser.getError().buffer());
        if (!value->data->getVersion().startsWith("4.3.")) throw std::runtime_error("Spine 4.3 export required");
        if (!value->data->getAnimations().size()) throw std::runtime_error("No animation");
        value->skeleton = std::make_unique<spine::Skeleton>(*value->data);
        value->skeleton->setSkin("default");
        value->skeleton->setupPose();
        value->skeleton->updateWorldTransform(spine::Physics_None);
        value->skeleton->getBounds(value->bounds[0], value->bounds[1], value->bounds[2], value->bounds[3]);
        if (!(value->bounds[2] > 0 && value->bounds[3] > 0)) {
            value->bounds[0] = value->data->getX(); value->bounds[1] = value->data->getY();
            value->bounds[2] = value->data->getWidth(); value->bounds[3] = value->data->getHeight();
        }
        return value.release();
    } catch (const std::exception &e) { failure(error, capacity, e.what()); }
      catch (...) { failure(error, capacity, "Spine load failed"); }
    return nullptr;
}
extern "C" void mv_spine_destroy(MVSpine *v) { std::lock_guard<std::mutex> lock(runtimeMutex); delete v; }
extern "C" int32_t mv_spine_page_count(MVSpine *v) { return int32_t(v->atlas->getPages().size()); }
extern "C" const char *mv_spine_page_name(MVSpine *v, int32_t i) { return v->atlas->getPages()[i]->name.buffer(); }
extern "C" void mv_spine_page_info(MVSpine *v, int32_t i, int32_t *out) {
    auto p = v->atlas->getPages()[i]; out[0]=p->width; out[1]=p->height; out[2]=p->pma;
    out[3]=p->minFilter; out[4]=p->magFilter; out[5]=p->uWrap; out[6]=p->vWrap;
}
extern "C" int32_t mv_spine_animation_count(MVSpine *v) { return int32_t(v->data->getAnimations().size()); }
extern "C" const char *mv_spine_animation_name(MVSpine *v, int32_t i) { return v->data->getAnimations()[i]->getName().buffer(); }
extern "C" double mv_spine_animation_duration(MVSpine *v, int32_t i) { return v->data->getAnimations()[i]->getDuration(); }
extern "C" void mv_spine_bounds(MVSpine *v, float *b) { std::memcpy(b, v->bounds, sizeof(v->bounds)); }
extern "C" int32_t mv_spine_evaluate(MVSpine *v, const char *name, double time, int32_t loop, char *error, int32_t capacity) {
    std::lock_guard<std::mutex> lock(runtimeMutex);
    try {
        if (!std::isfinite(time) || time < 0 || time > 1e12) throw std::runtime_error("Invalid Spine time");
        auto animation = v->data->findAnimation(name);
        if (!animation) throw std::runtime_error("Animation not found");
        double duration = animation->getDuration();
        double poseTime = duration > 0 ? (loop ? std::fmod(time,duration) : std::min(time,duration)) : 0;
        v->skeleton->setupPose();
        animation->apply(*v->skeleton, -1, float(poseTime), false, nullptr, 1, spine::MixFrom_Setup, false, false, false);
        v->skeleton->updateWorldTransform(spine::Physics_None);
        v->vertices.clear(); v->indices.clear(); v->commands.clear();
        for (auto c = v->renderer.render(*v->skeleton); c; c = c->next) {
            if (c->blendMode != spine::BlendMode_Normal) throw std::runtime_error("Only normal blend is supported");
            if (c->numVertices < 0 || c->numIndices < 0 || v->vertices.size()+c->numVertices > 1000000 || v->indices.size()+c->numIndices > 6000000)
                throw std::runtime_error("Spine geometry budget exceeded");
            uint32_t base = uint32_t(v->vertices.size()), start = uint32_t(v->indices.size());
            for (int i=0;i<c->numVertices;i++) {
                if (c->darkColors[i] & 0x00ffffff) throw std::runtime_error("Tint black is not supported");
                uint32_t color=c->colors[i];
                MVSpineVertex vertex={c->positions[i*2],c->positions[i*2+1],c->uvs[i*2],c->uvs[i*2+1],
                    float((color>>16)&255)/255, float((color>>8)&255)/255,float(color&255)/255,float((color>>24)&255)/255};
                if (!std::isfinite(vertex.x)||!std::isfinite(vertex.y)||!std::isfinite(vertex.u)||!std::isfinite(vertex.v)) throw std::runtime_error("Invalid Spine vertex");
                v->vertices.push_back(vertex);
            }
            for (int i=0;i<c->numIndices;i++) { if (c->indices[i]>=c->numVertices) throw std::runtime_error("Invalid Spine index"); v->indices.push_back(base+c->indices[i]); }
            int page=int(intptr_t(c->texture))-1;
            if (page<0 || page>=mv_spine_page_count(v)) throw std::runtime_error("Invalid atlas page");
            v->commands.push_back({page,start,uint32_t(c->numIndices)});
        }
        return 1;
    } catch (const std::exception &e) { failure(error,capacity,e.what()); }
      catch (...) { failure(error,capacity,"Spine evaluation failed"); }
    v->vertices.clear(); v->indices.clear(); v->commands.clear(); return 0;
}
extern "C" const MVSpineVertex *mv_spine_vertices(MVSpine *v,int32_t *n) { *n=int32_t(v->vertices.size());return v->vertices.data(); }
extern "C" const uint32_t *mv_spine_indices(MVSpine *v,int32_t *n) { *n=int32_t(v->indices.size());return v->indices.data(); }
extern "C" const MVSpineCommand *mv_spine_commands(MVSpine *v,int32_t *n) { *n=int32_t(v->commands.size());return v->commands.data(); }

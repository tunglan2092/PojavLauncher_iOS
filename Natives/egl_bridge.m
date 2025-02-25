#include "jni.h"
#include <assert.h>
#include <dlfcn.h>

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>

#include "EGL/egl.h"
#include "EGL/eglext.h"
#include "GL/osmesa.h"
#include "GLES2/gl2.h"

#include "egl_bridge.h"
#include "osmesa_internal.h"

#include "log.h"
#include "utils.h"
// region OSMESA internals


// endregion OSMESA internals
struct PotatoBridge {
	/* EGLContext */ void* eglContextOld;
	/* EGLContext */ void* eglContext;
	/* EGLDisplay */ void* eglDisplay;
	/* EGLSurface */ void* eglSurface;
/*
	void* eglSurfaceRead;
	void* eglSurfaceDraw;
*/
};
EGLConfig config;
pid_t mainThreadID;
struct PotatoBridge potatoBridge;

/* OSMesa functions */
GLboolean (*OSMesaMakeCurrent_p) (OSMesaContext ctx, void *buffer, GLenum type,
                                  GLsizei width, GLsizei height);
OSMesaContext (*OSMesaGetCurrentContext_p) (void);
OSMesaContext  (*OSMesaCreateContext_p) (GLenum format, OSMesaContext sharelist);
void (*OSMesaDestroyContext_p) (OSMesaContext ctx);
void (*OSMesaPixelStore_p) ( GLint pname, GLint value );
GLubyte* (*glGetString_p) (GLenum name);
void (*glFinish_p) (void);
void (*glClearColor_p) (GLclampf red, GLclampf green, GLclampf blue, GLclampf alpha);
void (*glClear_p) (GLbitfield mask);

/*EGL functions */
EGLBoolean (*eglMakeCurrent_p) (EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext ctx);
EGLBoolean (*eglDestroyContext_p) (EGLDisplay dpy, EGLContext ctx);
EGLBoolean (*eglDestroySurface_p) (EGLDisplay dpy, EGLSurface surface);
EGLBoolean (*eglTerminate_p) (EGLDisplay dpy);
EGLBoolean (*eglReleaseThread_p) (void);
EGLContext (*eglGetCurrentContext_p) (void);
EGLDisplay (*eglGetPlatformDisplay_p) (EGLenum platform, void *native_display, const EGLint *attrib_list);
EGLBoolean (*eglInitialize_p) (EGLDisplay dpy, EGLint *major, EGLint *minor);
EGLBoolean (*eglChooseConfig_p) (EGLDisplay dpy, const EGLint *attrib_list, EGLConfig *configs, EGLint config_size, EGLint *num_config);
EGLBoolean (*eglGetConfigAttrib_p) (EGLDisplay dpy, EGLConfig config, EGLint attribute, EGLint *value);
EGLBoolean (*eglBindAPI_p) (EGLenum api);
EGLSurface (*eglCreateWindowSurface_p) (EGLDisplay dpy, EGLConfig config, NativeWindowType window, const EGLint *attrib_list);
EGLBoolean (*eglSwapBuffers_p) (EGLDisplay dpy, EGLSurface draw);
EGLint (*eglGetError_p) (void);
EGLContext (*eglCreateContext_p) (EGLDisplay dpy, EGLConfig config, EGLContext share_list, const EGLint *attrib_list);
EGLBoolean (*eglSwapInterval_p) (EGLDisplay dpy, EGLint interval);
EGLSurface (*eglGetCurrentSurface_p) (EGLint readdraw);

int (*vtest_main_p) (int, const char*[]);
void (*vtest_swap_buffers_p) (void);
void* egl_make_current(void* window);

#define RENDERER_MTL_ANGLE 1
#define RENDERER_VK_ZINK 2
#define RENDERER_VIRGL 3

int config_renderer;

typedef void gl4esInitialize_func();
// typedef void gl4esSwapBuffers_func();
// gl4esSwapBuffers_func *gl4esSwapBuffers;
typedef jint RegalMakeCurrent_func(EGLContext context);

// Called from JNI_OnLoad of liblwjgl_opengl, TODO: check if unused
void pojav_openGLOnLoad() {
}
void pojav_openGLOnUnload() {
}

pid_t gettid() {
    return (pid_t) pthread_mach_thread_np(pthread_self());
}


JNIEXPORT void JNICALL Java_net_kdt_pojavlaunch_utils_JREUtils_setenv(JNIEnv *env, jclass clazz, jstring name, jstring value, jboolean overwrite) {
    char const *name_c = (*env)->GetStringUTFChars(env, name, NULL);
    char const *value_c = (*env)->GetStringUTFChars(env, value, NULL);

    setenv(name_c, value_c, overwrite);

    (*env)->ReleaseStringUTFChars(env, name, name_c);
    (*env)->ReleaseStringUTFChars(env, value, value_c);
}

void pojavTerminate() {
    debug("EGLBridge: Terminating");

    switch (config_renderer) {
        case RENDERER_MTL_ANGLE: {
            eglMakeCurrent_p(potatoBridge.eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            eglDestroySurface_p(potatoBridge.eglDisplay, potatoBridge.eglSurface);
            eglDestroyContext_p(potatoBridge.eglDisplay, potatoBridge.eglContext);
            eglTerminate_p(potatoBridge.eglDisplay);
            eglReleaseThread_p();
    
            potatoBridge.eglContext = EGL_NO_CONTEXT;
            potatoBridge.eglDisplay = EGL_NO_DISPLAY;
            potatoBridge.eglSurface = EGL_NO_SURFACE;
        } break;
        
        case RENDERER_VK_ZINK: {
            // Nothing to do here
        } break;
    }
}

void* pojavGetCurrentContext() {
    switch (config_renderer) {
        case RENDERER_MTL_ANGLE:
            return (void *)eglGetCurrentContext_p();

        case RENDERER_VIRGL:
        case RENDERER_VK_ZINK:
            return (void *)OSMesaGetCurrentContext_p();

        default: return NULL;
    }
}

void dlsym_EGL(void* dl_handle) {
    eglBindAPI_p = dlsym(dl_handle,"eglBindAPI");
    eglChooseConfig_p = dlsym(dl_handle, "eglChooseConfig");
    eglCreateContext_p = dlsym(dl_handle, "eglCreateContext");
    eglCreateWindowSurface_p = dlsym(dl_handle, "eglCreateWindowSurface");
    eglDestroyContext_p = dlsym(dl_handle, "eglDestroyContext");
    eglDestroySurface_p = dlsym(dl_handle, "eglDestroySurface");
    eglGetConfigAttrib_p = dlsym(dl_handle, "eglGetConfigAttrib");
    eglGetCurrentContext_p = dlsym(dl_handle, "eglGetCurrentContext");
    //eglGetDisplay = replaced with eglGetPlatformDisplay
    eglGetError_p = dlsym(dl_handle, "eglGetError");
    eglGetPlatformDisplay_p = dlsym(dl_handle, "eglGetPlatformDisplay");
    eglInitialize_p = dlsym(dl_handle, "eglInitialize");
    eglMakeCurrent_p = dlsym(dl_handle, "eglMakeCurrent");
    eglSwapBuffers_p = dlsym(dl_handle, "eglSwapBuffers");
    eglReleaseThread_p = dlsym(dl_handle, "eglReleaseThread");
    eglSwapInterval_p = dlsym(dl_handle, "eglSwapInterval");
    eglTerminate_p = dlsym(dl_handle, "eglTerminate");
    eglGetCurrentSurface_p = dlsym(dl_handle,"eglGetCurrentSurface");
}

void dlsym_OSMesa(void* dl_handle) {
    OSMesaMakeCurrent_p = dlsym(dl_handle,"OSMesaMakeCurrent");
    OSMesaGetCurrentContext_p = dlsym(dl_handle,"OSMesaGetCurrentContext");
    OSMesaCreateContext_p = dlsym(dl_handle, "OSMesaCreateContext");
    OSMesaDestroyContext_p = dlsym(dl_handle, "OSMesaDestroyContext");
    OSMesaPixelStore_p = dlsym(dl_handle,"OSMesaPixelStore");
    glGetString_p = dlsym(dl_handle,"glGetString");
    glClearColor_p = dlsym(dl_handle, "glClearColor");
    glClear_p = dlsym(dl_handle,"glClear");
    glFinish_p = dlsym(dl_handle,"glFinish");
}

void loadSymbols() {
    char fileName[2048];
    switch (config_renderer) {
        case RENDERER_VK_ZINK:
            sprintf((char *)fileName, "%s/Frameworks/%s.framework/%s", getenv("BUNDLE_PATH"), getenv("POJAV_RENDERER"), getenv("POJAV_RENDERER"));
            break;
        case RENDERER_MTL_ANGLE:
            sprintf((char *)fileName, "%s/Frameworks/MetalANGLE.framework/MetalANGLE", getenv("BUNDLE_PATH"));
            break;
    }
    void* dl_handle = dlopen(fileName,RTLD_NOW|RTLD_GLOBAL|RTLD_NODELETE);

    if(dl_handle == NULL) {
        NSLog(@"DlLoader: unable to load: %s", dlerror());
        return;
    }
    switch(config_renderer) {
        case RENDERER_VK_ZINK:
            dlsym_OSMesa(dl_handle);
            break;
        case RENDERER_MTL_ANGLE:
            dlsym_EGL(dl_handle);
            break;
    }
}

void loadSymbolsVirGL() {
    config_renderer = RENDERER_MTL_ANGLE;
    loadSymbols();
    config_renderer = RENDERER_VK_ZINK;
    loadSymbols();
    config_renderer = RENDERER_VIRGL;

    char fileName[2048];
    sprintf((char *)fileName, "%s/Frameworks/libvirgl_test_server.dylib.framework/libvirgl_test_server.dylib", getenv("BUNDLE_PATH"));
    void *handle = dlopen(fileName, RTLD_LAZY);
    NSLog(@"VirGL: libvirgl_test_server = %p", handle);
    if (!handle) {
        NSLog(@"VirGL: %s", dlerror());
        return;
    }
    vtest_main_p = dlsym(handle, "vtest_main");
    vtest_swap_buffers_p = dlsym(handle, "vtest_swap_buffers");
}

int pojavInit() {
    isInputReady = 1;
    mainThreadID = gettid();

    NSString *renderer = @(getenv("POJAV_RENDERER"));
    BOOL isVGPU = [renderer hasPrefix:@"libvgpu"];
    if ([renderer isEqualToString:@"libOSMesa.8.dylib"]) {
        config_renderer = RENDERER_VIRGL;
        setenv("GALLIUM_DRIVER", "virpipe", 1);
        loadSymbolsVirGL();
    } else if ([renderer hasPrefix:@"libgl4es"] || [renderer hasPrefix:@"libtinygl4angle"] || isVGPU) {
        config_renderer = RENDERER_MTL_ANGLE;
        loadSymbols();
    } else if ([renderer hasPrefix:@"libOSMesa"]) {
        config_renderer = RENDERER_VK_ZINK;
        setenv("GALLIUM_DRIVER","zink",1);
        loadSymbols();
    }

    
    if (config_renderer == RENDERER_MTL_ANGLE || config_renderer == RENDERER_VIRGL) {
        if (potatoBridge.eglDisplay == EGL_NO_DISPLAY) {
            potatoBridge.eglDisplay = eglGetPlatformDisplay_p(EGL_PLATFORM_ANGLE_ANGLE, (void *)EGL_DEFAULT_DISPLAY, NULL);
            if (potatoBridge.eglDisplay == EGL_NO_DISPLAY) {
                NSLog(@"EGLBridge: Error eglGetDefaultDisplay() failed: 0x%x", eglGetError_p());
                return JNI_FALSE;
            }
        }

        NSLog(@"EGLBridge: Initializing");
        // printf("EGLBridge: ANativeWindow pointer = %p\n", potatoBridge.androidWindow);
        //(*env)->ThrowNew(env,(*env)->FindClass(env,"java/lang/Exception"),"Trace exception");
        if (!eglInitialize_p(potatoBridge.eglDisplay, NULL, NULL)) {
            NSLog(@"EGLBridge: Error eglInitialize() failed: 0x%x", eglGetError_p());
            return JNI_FALSE;
        }

        static const EGLint attribs[] = {
                EGL_RED_SIZE, 8,
                EGL_GREEN_SIZE, 8,
                EGL_BLUE_SIZE, 8,
                EGL_ALPHA_SIZE, 8,
                // Minecraft required on initial 24
                EGL_DEPTH_SIZE, 24,
                EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                EGL_NONE
        };

        EGLint num_configs;
        EGLint vid;

        if (!eglChooseConfig_p(potatoBridge.eglDisplay, attribs, &config, 1, &num_configs)) {
            NSLog(@"EGLBridge: Error couldn't get an EGL visual config: 0x%x", eglGetError_p());
            return JNI_FALSE;
        }

        assert(config);
        assert(num_configs > 0);

        if (!eglGetConfigAttrib_p(potatoBridge.eglDisplay, config, EGL_NATIVE_VISUAL_ID, &vid)) {
            NSLog(@"EGLBridge: Error eglGetConfigAttrib() failed: 0x%x", eglGetError_p());
            return JNI_FALSE;
        }

        //ANativeWindow_setBuffersGeometry(potatoBridge.androidWindow, 0, 0, vid);

        if (/*!isVGPU &&*/ !eglBindAPI_p(EGL_OPENGL_API)) {
            NSLog(@"EGLBridge: Failed to bind EGL_OPENGL_API, falling back to EGL_OPENGL_ES_API, error=0x%x", eglGetError_p());
            eglBindAPI_p(EGL_OPENGL_ES_API);
        } else if (isVGPU) {
            eglBindAPI_p(EGL_OPENGL_ES_API);
        }

        potatoBridge.eglSurface = eglCreateWindowSurface_p(potatoBridge.eglDisplay, config, (__bridge EGLNativeWindowType) ((SurfaceViewController *)viewController).surfaceView.layer, NULL);
        //NSLog(@"Layer %@", ((SurfaceViewController *)viewController).surfaceView.layer);

        if (!potatoBridge.eglSurface) {
            NSLog(@"EGLBridge: Error eglCreateWindowSurface failed: 0x%x", eglGetError_p());
            //(*env)->ThrowNew(env,(*env)->FindClass(env,"java/lang/Exception"),"Trace exception");
            return JNI_FALSE;
        }

        NSLog(@"EGLBridge: Initialized!");
        NSLog(@"EGLBridge: ThreadID=%d", gettid());
        NSLog(@"EGLBridge: EGLDisplay=%p, EGLSurface=%p",
/* window==0 ? EGL_NO_CONTEXT : */
               potatoBridge.eglDisplay,
               potatoBridge.eglSurface
        );
        if (config_renderer != RENDERER_VIRGL) {
            return JNI_TRUE;
        }
    // } else if (strcmp(renderer, "vulkan_zink") == 0) {
    }

    if (config_renderer == RENDERER_VIRGL) {
        // Init EGL context and vtest server
        const EGLint ctx_attribs[] = {
            EGL_CONTEXT_CLIENT_VERSION, 3,
            EGL_NONE
        };
        EGLContext* ctx = eglCreateContext_p(potatoBridge.eglDisplay, config, NULL, ctx_attribs);
        NSLog(@"VirGL: created EGL context %p", ctx);

        pthread_t t;
        pthread_create(&t, NULL, egl_make_current, (void *)ctx);
        usleep(100*1000); // need enough time for the server to init
    }

    if (config_renderer == RENDERER_VK_ZINK || config_renderer == RENDERER_VIRGL) {
        if(OSMesaCreateContext_p == NULL) {
            NSLog(@"OSMDroid: %s",dlerror());
            return JNI_FALSE;
        }
        
        NSLog(@"OSMDroid: width=%i;height=%i, reserving %i bytes for frame buffer", savedWidth, savedHeight,
             savedWidth * 4 * savedHeight);
        gbuffer = malloc(savedWidth * 4 * savedHeight+1);
        if (gbuffer) {
            NSLog(@"OSMDroid: created frame buffer");
            return JNI_TRUE;
        } else {
            NSLog(@"OSMDroid: can't generate frame buffer");
            return JNI_FALSE;
        }
    }
    
    return JNI_FALSE;
}

int32_t stride;
bool stopSwapBuffers;
void pojavSwapBuffers() {
    if (stopSwapBuffers) {
        return;
    }
    switch (config_renderer) {
        case RENDERER_MTL_ANGLE: {
            if (!eglSwapBuffers_p(potatoBridge.eglDisplay, potatoBridge.eglSurface)) {
                if (eglGetError_p() == EGL_BAD_SURFACE) {
                    stopSwapBuffers = true;
                    closeGLFWWindow();
                }
            }
        } break;

        case RENDERER_VIRGL: {
            glFinish_p();
            vtest_swap_buffers_p();
        } break;

        case RENDERER_VK_ZINK: {
            glFinish_p();
            dispatch_async(dispatch_get_main_queue(), ^{
                [((SurfaceViewController *)viewController).surfaceView displayLayer];
            });
        } break;
    }
}

void* egl_make_current(void* window) {
    EGLBoolean success = eglMakeCurrent_p(
        potatoBridge.eglDisplay,
        window==0 ? (EGLSurface *) 0 : potatoBridge.eglSurface,
        window==0 ? (EGLSurface *) 0 : potatoBridge.eglSurface,
        /* window==0 ? EGL_NO_CONTEXT : */ (EGLContext *) window
    );

    if (success == EGL_FALSE) {
        NSLog(@"EGLBridge: Error: eglMakeCurrent() failed: 0x%x", eglGetError_p());
    } else {
        NSLog(@"EGLBridge: eglMakeCurrent() succeed!");
    }

    if (config_renderer == RENDERER_VIRGL) {
        NSLog(@"VirGL: vtest_main = %p", vtest_main_p);
        NSLog(@"VirGL: Calling VTest server's main function");
        vtest_main_p(3, (const char*[]){"vtest", "--no-loop-or-fork", "--use-gles", NULL, NULL});
    }

    return NULL;
}

void pojavMakeCurrent(void* window) {
    //if(OSMesaGetCurrentContext_p() != NULL) {
    //    printf("OSMDroid: skipped context reset\n");
    //    return JNI_TRUE;
    //}
    
    if (config_renderer == RENDERER_MTL_ANGLE) {
            EGLContext *currCtx = eglGetCurrentContext_p();
            NSLog(@"EGLBridge: Comparing: thr=%d, this=%p, curr=%p", gettid(), window, currCtx);
            if (currCtx == NULL || window == 0) {
                NSLog(@"EGLBridge: Making current on window %p on thread %d", window, gettid());
                egl_make_current((void *)window);

                // Test
#ifdef GLES_TEST
                glClearColor(0.4f, 0.4f, 0.4f, 1.0f);
                glClear(GL_COLOR_BUFFER_BIT);
                eglSwapBuffers(potatoBridge.eglDisplay, potatoBridge.eglSurface);
                NSLog(@"First frame error: 0x%x", eglGetError());
#endif

                // ADDITIONAL STEP ON IOS: Initialize gl4es
                void *gl4es_handle = dlopen(getenv("POJAV_RENDERER"), RTLD_GLOBAL);
                debug("%s=%p, error=%s", getenv("POJAV_RENDERER"), gl4es_handle, dlerror());

                gl4esInitialize_func *gl4esInitialize = (gl4esInitialize_func*) dlsym(gl4es_handle, "initialize_gl4es");
                // debug("initialize_gl4es = %p", gl4esInitialize);
                if (gl4esInitialize) {
                    gl4esInitialize();
                } else {
                    debug("%s", dlerror());
                }
                NSLog(@"Renderer init success");

                return;
            } else {
                // (*env)->ThrowNew(env,(*env)->FindClass(env,"java/lang/Exception"),"Trace exception");
                return;
            }
    }

    if (config_renderer == RENDERER_VK_ZINK || config_renderer == RENDERER_VIRGL) {
            NSLog(@"OSMDroid: making current");
            OSMesaMakeCurrent_p((OSMesaContext)window,gbuffer,GL_UNSIGNED_BYTE,savedWidth,savedHeight);
            if (config_renderer == RENDERER_VK_ZINK) {
                OSMesaPixelStore_p(OSMESA_ROW_LENGTH,savedWidth);
                OSMesaPixelStore_p(OSMESA_Y_UP,0);
            }

            NSLog(@"OSMDroid: vendor: %s",glGetString_p(GL_VENDOR));
            NSLog(@"OSMDroid: renderer: %s",glGetString_p(GL_RENDERER));
            NSLog(@"OSMDroid: extensions: %s",glGetString_p(GL_EXTENSIONS));
            glClear_p(GL_COLOR_BUFFER_BIT);
            glClearColor_p(0.4f, 0.4f, 0.4f, 1.0f);
            pojavSwapBuffers();
            return;
    }

    // should not reach here
    NSLog(@"Error: Invalid renderer %d, aborting.", config_renderer);
    abort();
}

void* pojavCreateContext(void* contextSrc) {
    if (config_renderer == RENDERER_MTL_ANGLE) {
            const EGLint ctx_attribs[] = {
                EGL_CONTEXT_CLIENT_VERSION, 3,
                EGL_NONE
            };
            EGLContext* ctx = eglCreateContext_p(potatoBridge.eglDisplay, config, (void*)contextSrc, ctx_attribs);
            potatoBridge.eglContext = ctx;
            NSLog(@"EGLBridge: Created CTX pointer = %p",ctx);
            //(*env)->ThrowNew(env,(*env)->FindClass(env,"java/lang/Exception"),"Trace exception");
            return (void *)ctx;
    }

    if (config_renderer == RENDERER_VK_ZINK || config_renderer == RENDERER_VIRGL) {
            NSLog(@"OSMDroid: generating context");
            void* ctx = OSMesaCreateContext_p(OSMESA_RGBA,contextSrc);
            NSLog(@"OSMDroid: context=%p",ctx);
            return ctx;
    }

    return NULL;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_GL_nativeRegalMakeCurrent(JNIEnv *env, jclass clazz) {
    //NSLog(@"Regal: making current");
    
    //RegalMakeCurrent_func *RegalMakeCurrent = (RegalMakeCurrent_func *) dlsym(RTLD_DEFAULT, "RegalMakeCurrent");
    //assert(RegalMakeCurrent);
    //RegalMakeCurrent(potatoBridge.eglContext);

    NSLog(@"Regal removed");
    abort();
}

JNIEXPORT jlong JNICALL
Java_org_lwjgl_opengl_GL_getGraphicsBufferAddr(JNIEnv *env, jobject thiz) {
    return (jlong)&gbuffer;
}
JNIEXPORT jintArray JNICALL
Java_org_lwjgl_opengl_GL_getNativeWidthHeight(JNIEnv *env, jobject thiz) {
    jintArray ret = (*env)->NewIntArray(env,2);
    jint arr[] = {savedWidth, savedHeight};
    (*env)->SetIntArrayRegion(env,ret,0,2,arr);
    return ret;
}

void pojavSwapInterval(int interval) {
    switch (config_renderer) {
        case RENDERER_MTL_ANGLE:
        case RENDERER_VIRGL: {
            eglSwapInterval_p(potatoBridge.eglDisplay, interval);
        } break;

        case RENDERER_VK_ZINK: {
            NSLog(@"eglSwapInterval: NOT IMPLEMENTED YET!");
            // Nothing to do here
        } break;
    }
}

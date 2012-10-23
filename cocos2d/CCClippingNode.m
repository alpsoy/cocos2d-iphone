/*
 * cocos2d for iPhone: http://www.cocos2d-iphone.org
 *
 * Copyright (c) 2012 Pierre-David Bélanger
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 */

#import "CCClippingNode.h"

#import "CCGL.h"
#import "OpenGL_Internal.h"

#import "CCGLProgram.h"
#import "CCShaderCache.h"

#import "kazmath/GL/matrix.h"

static GLint _stencilBits = -1;

static void setProgram(CCNode *n, CCGLProgram *p) {
    n.shaderProgram = p;
    if (!n.children) return;
    CCNode *c;
    CCARRAY_FOREACH(n.children, c) setProgram(c, p);
    
}

@implementation CCClippingNode

@synthesize stencil = stencil_;
@synthesize alphaThreshold = alphaThreshold_;
@synthesize inverted = inverted_;

- (void)dealloc
{
    [stencil_ release];
    [super dealloc];
}

+ (id)clippingNode
{
    return [self node];
}

+ (id)clippingNodeWithStencil:(CCNode *)stencil
{
    return [[[self alloc] initWithStencil:stencil] autorelease];
}

- (id)init
{
    return [self initWithStencil:nil];
}

- (id)initWithStencil:(CCNode *)stencil
{
    if (self = [super init]) {
        self.stencil = stencil;
        self.alphaThreshold = 1;
        self.inverted = NO;
        // get (only once) the number of bits of the stencil buffer
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            glGetIntegerv(GL_STENCIL_BITS, &_stencilBits);
            // warn if the stencil buffer is not enabled
            if (_stencilBits <= 0) {
#if defined(__CC_PLATFORM_IOS)
                CCLOGWARN(@"Stencil buffer is not enabled; enable it by passing GL_DEPTH24_STENCIL8_OES into the depthFormat parrameter when initializing CCGLView. Until then, everything will be drawn without stencil.");
#elif defined(__CC_PLATFORM_MAC)
                CCLOGWARN(@"Stencil buffer is not enabled; enable it by setting the Stencil attribue to 8 bit in the Attributes inspector of the CCGLView view object in MainMenu.xib, or programmatically by adding NSOpenGLPFAStencilSize and 8 in the NSOpenGLPixelFormatAttribute array of the NSOpenGLPixelFormat used when initializing CCGLView. Until then, everything will be drawn without stencil.");
#endif
            }
        });
    }
    return self;
}

- (void)onEnter
{
    [super onEnter];
    [stencil_ onEnter];
}

- (void)onEnterTransitionDidFinish
{
    [super onEnterTransitionDidFinish];
    [stencil_ onEnterTransitionDidFinish];
}

- (void)onExitTransitionDidStart
{
    [stencil_ onExitTransitionDidStart];
    [super onExitTransitionDidStart];
}

- (void)onExit
{
    [stencil_ onExit];
    [super onExit];
}

- (void)visit
{
    // if stencil buffer disabled
    if (_stencilBits < 1) {
        // draw everything, as if there where no stencil
        [super visit];
        return;
    }
    
    // return fast (draw nothing, or draw everything if in inverted mode) if:
    // - nil stencil node
    // - or stencil node invisible:
    if (!stencil_ || !stencil_.visible) {
        if (inverted_) {
            // draw everything
            [super visit];
        }
        return;
    }

    // store the current stencil layer (position in the stencil buffer),
    // this will allow nesting up to n CCClippingNode,
    // where n is the number of bits of the stencil buffer.
    static GLint layer = -1;
    
    // all the _stencilBits are in use?
    if (layer + 1 == _stencilBits) {
        // warn once
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            CCLOGWARN(@"Nesting more than %d stencils is not supported. Everything will be drawn without stencil for this node and its childs.", _stencilBits);
        });
        // draw everything, as if there where no stencil
        [super visit];
        return;
    }
    
    ///////////////////////////////////
    // INIT

    // all 0 mask
    static const GLuint mask_zeros = 0;
    // all 1 mask
    static const GLuint mask_ones = ~0;
    
    // increment the current layer
    layer++;
    
    // mask of the current layer (ie: for layer 3: 00000100)
    GLint mask_layer = 0x1 << layer;
    // mask of all layers less than the current (ie: for layer 3: 00000011)
    GLint mask_layer_l = mask_layer - 1;
    // mask of all layers less than or equal to the current (ie: for layer 3: 00000111)
    GLint mask_layer_le = mask_layer | mask_layer_l;
    
    // manually save the stencil state (if someone was using it)
    GLboolean currentStencilEnabled = GL_FALSE;
    GLuint currentStencilWriteMask = mask_ones;
    GLenum currentStencilFunc = GL_ALWAYS;
    GLint currentStencilRef = 0;
    GLuint currentStencilValueMask = mask_ones;
    GLenum currentStencilFail = GL_KEEP;
    GLenum currentStencilPassDepthFail = GL_KEEP;
    GLenum currentStencilPassDepthPass = GL_KEEP;
    currentStencilEnabled = glIsEnabled(GL_STENCIL_TEST);
    if (currentStencilEnabled) {
        glGetIntegerv(GL_STENCIL_WRITEMASK, (GLint *)&currentStencilWriteMask);
        glGetIntegerv(GL_STENCIL_FUNC, (GLint *)&currentStencilFunc);
        glGetIntegerv(GL_STENCIL_REF, &currentStencilRef);
        glGetIntegerv(GL_STENCIL_VALUE_MASK, (GLint *)&currentStencilValueMask);
        glGetIntegerv(GL_STENCIL_FAIL, (GLint *)&currentStencilFail);
        glGetIntegerv(GL_STENCIL_PASS_DEPTH_FAIL, (GLint *)&currentStencilPassDepthFail);
        glGetIntegerv(GL_STENCIL_PASS_DEPTH_PASS, (GLint *)&currentStencilPassDepthPass);
    }
    
    // enable stencil use
    glEnable(GL_STENCIL_TEST);
    // check for OpenGL error while enabling stencil test
    CHECK_GL_ERROR_DEBUG();
    
    // all bits on the stencil buffer are readonly, except the current layer bit,
    // this means that operation like glClear or glStencilOp will be masked with this value
    glStencilMask(mask_layer);
    
    // value to use when clearing the stencil buffer
    // all 0, or all 1 if in inverted mode
    glClearStencil(!inverted_ ? mask_zeros : mask_ones);
    
    // clear the stencil buffer
    glClear(GL_STENCIL_BUFFER_BIT);
    
    ///////////////////////////////////
    // DRAW CLIPPING STENCIL

    // setup the stencil test func like this:
    // for each pixel in the stencil node
    //     never draw it into the frame buffer
    //     if not in inverted mode: set the current layer value to 1 in the stencil buffer
    //     if in inverted mode: set the current layer value to 0 in the stencil buffer
    glStencilFunc(GL_NEVER, mask_layer, mask_layer);
    glStencilOp(!inverted_ ? GL_REPLACE : GL_ZERO, GL_KEEP, GL_KEEP);
    
    // enable alpha test only if the alpha threshold < 1,
    // indeed if alpha threshold == 1, every pixel will be drawn anyways
#if defined(__CC_PLATFORM_MAC)
    GLboolean currentAlphaTestEnabled = GL_FALSE;
    GLenum currentAlphaTestFunc = GL_ALWAYS;
    GLclampf currentAlphaTestRef = 1;
#endif
    if (alphaThreshold_ < 1) {
#if defined(__CC_PLATFORM_IOS)
        // since glAlphaTest do not exists in OES, use a shader that writes
        // pixel only if greater than an alpha threshold
        CCGLProgram *program = [[CCShaderCache sharedShaderCache] programForKey:kCCShader_PositionTextureColorAlphaTest];
        GLint alphaValueLocation = glGetUniformLocation(program->program_, kCCUniformAlphaTestValue);
        // set our alphaThreshold
        [program setUniformLocation:alphaValueLocation withF1:alphaThreshold_];
        // we need to recursively apply this shader to all the nodes in the stencil node
        // XXX: we should have a way to apply shader to all nodes without having to do this
        setProgram(stencil_, program);
#elif defined(__CC_PLATFORM_MAC)
        // manually save the alpha test state (if someone was using it)
        currentAlphaTestEnabled = glIsEnabled(GL_ALPHA_TEST);
        if (currentAlphaTestEnabled) {
            glGetIntegerv(GL_ALPHA_TEST_FUNC, (GLint *)&currentAlphaTestFunc);
            glGetFloatv(GL_ALPHA_TEST_REF, &currentAlphaTestRef);
        }
        // enable alpha testing
        glEnable(GL_ALPHA_TEST);
        // check for OpenGL error while enabling alpha test
        CHECK_GL_ERROR_DEBUG();
        // pixel will be drawn only if greater than an alpha threshold
        glAlphaFunc(GL_GREATER, alphaThreshold_);
#endif
    }

    // draw the stencil node as if it was one of our child
    // (according to the stencil test func/op and alpha (or alpha shader) test)
    kmGLPushMatrix();
    [self transform];
    [stencil_ visit];
    kmGLPopMatrix();
    
    // restore alpha test state
    if (alphaThreshold_ < 1) {
#if defined(__CC_PLATFORM_IOS)
        // XXX: we need to find a way to restore the shaders of the stencil node and its childs
#elif defined(__CC_PLATFORM_MAC)
        // manually restore the alpha test state (if someone was using it)
        if (currentAlphaTestEnabled) {
            glAlphaFunc(currentAlphaTestFunc, currentAlphaTestRef);
        } else {
            glDisable(GL_ALPHA_TEST);
        }
#endif
    }
    
    ///////////////////////////////////
    // DRAW CONTENT
    
    // setup the stencil test func like this:
    // for each pixel of this node and its childs
    //     if all layers less than or equals to the current are set to 1 in the stencil buffer
    //         draw the pixel and keep the current layer in the stencil buffer
    //     else
    //         do not draw the pixel but keep the current layer in the stencil buffer
    glStencilFunc(GL_EQUAL, mask_layer_le, mask_layer_le);
    glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
    
    // draw (according to the stencil test func) this node and its childs
    [super visit];
    
    ///////////////////////////////////
    // CLEANUP
    
    // manually restore the stencil state (if someone was using it)
    if (currentStencilEnabled) {
        glStencilFunc(currentStencilFunc, currentStencilRef, currentStencilValueMask);
        glStencilOp(currentStencilFail, currentStencilPassDepthFail, currentStencilPassDepthPass);
        glStencilMask(currentStencilWriteMask);
    } else {
        glDisable(GL_STENCIL_TEST);
    }
    
    // we are done using this layer, decrement
    layer--;
}

@end
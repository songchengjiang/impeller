#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>

#include "scene.hpp"

using impeller2d::MetalRenderer;
using impeller2d::RenderResult;

@interface DemoView : NSView
- (instancetype)initWithRenderer:(MetalRenderer*)renderer presentOnce:(BOOL)presentOnce;
- (void)scheduleFrame;
@end

@implementation DemoView {
  MetalRenderer* _renderer;
  CAMetalLayer* _metal;
  BOOL _framePending;
  BOOL _presentOnce;
}

- (instancetype)initWithRenderer:(MetalRenderer*)renderer presentOnce:(BOOL)presentOnce {
  self = [super initWithFrame:NSMakeRect(0, 0, 720, 480)];
  if (self) {
    _renderer = renderer;
    _presentOnce = presentOnce;
    _metal = [CAMetalLayer layer];
    _metal.device = (__bridge id<MTLDevice>)renderer->device();
    _metal.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metal.framebufferOnly = NO;
    self.layer = _metal;
    self.wantsLayer = YES;
  }
  return self;
}

- (void)setFrameSize:(NSSize)size {
  const BOOL changed = !NSEqualSizes(self.frame.size, size);
  [super setFrameSize:size];
  if (changed) {
    [self scheduleFrame];
  }
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  [self scheduleFrame];
}

- (void)scheduleFrame {
  // A layer-hosting view schedules its own rendering.
  if (_framePending || !_metal || !self.window) {
    return;
  }
  _framePending = YES;
  __weak DemoView* weakView = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    DemoView* view = weakView;
    if (!view) {
      return;
    }
    view->_framePending = NO;
    if (view.window.isVisible && ![view renderFrame]) {
      std::fputs("Impeller2D could not render the window frame.\n", stderr);
      if (view->_presentOnce) {
        std::exit(1);
      }
    }
  });
}

- (BOOL)renderFrame {
  @autoreleasepool {
    const NSSize pixels = [self convertSizeToBacking:self.bounds.size];
    if (pixels.width <= 0 || pixels.height <= 0) {
      return YES;
    }
    _metal.contentsScale = self.window.backingScaleFactor;
    _metal.drawableSize = NSSizeToCGSize(pixels);
    auto list = RecordScene(*_renderer, pixels.width, pixels.height);
    id<CAMetalDrawable> drawable = [_metal nextDrawable];
    if (_presentOnce && drawable) {
      [drawable addPresentedHandler:^(id<MTLDrawable> frame) {
        if (frame.presentedTime <= 0) {
          std::fputs("Metal drawable was dropped before presentation.\n", stderr);
          std::exit(1);
        }
        std::puts("Metal drawable presented on screen.");
        std::exit(0);
      }];
    }
    return drawable && _renderer->present((__bridge void*)drawable, list) == RenderResult::Success;
  }
}

@end

@interface DemoDelegate : NSObject <NSApplicationDelegate>
@end

@implementation DemoDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
  return YES;
}
@end

int main(int argc, char* argv[]) {
  @autoreleasepool {
    const bool once = argc == 2 && std::strcmp(argv[1], "--once") == 0;
    if (argc != 1 && !once) {
      std::fputs("Usage: impeller2d_demo [--once]\n", stderr);
      return 2;
    }

    auto renderer = MetalRenderer::create();
    if (!renderer) {
      std::fputs("Impeller2D could not create a Metal context.\n", stderr);
      return 1;
    }

    NSApplication* app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    __attribute__((objc_precise_lifetime)) DemoDelegate* delegate = [DemoDelegate new];
    app.delegate = delegate;

    NSWindow* window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 720, 480)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"Impeller 2D";
    window.releasedWhenClosed = NO;
    DemoView* view = [[DemoView alloc] initWithRenderer:renderer.get() presentOnce:once];
    window.contentView = view;
    [window center];
    [window makeKeyAndOrderFront:nil];
    [app activateIgnoringOtherApps:YES];
    [view scheduleFrame];

    if (once) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(),
                     ^{
                       std::fputs("Timed out waiting for on-screen presentation.\n", stderr);
                       std::exit(1);
                     });
    }
    [app run];
  }
  return 0;
}

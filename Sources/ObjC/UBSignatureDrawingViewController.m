/**
 Copyright (c) 2017 Uber Technologies, Inc.
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
 */

#import "UBSignatureDrawingViewController.h"
#import "UBSignatureDrawingModelAsync.h"

@interface UBSignatureDrawingViewController ()

@property (nonatomic) BOOL isEmpty;

@property (nonatomic, readonly) UBSignatureDrawingModelAsync *model;
@property (nonatomic, readonly) NSOperationQueue *modelOperationQueue;
@property (nonatomic) CAShapeLayer *bezierPathLayer;

@property (nonatomic) UIImageView *imageView;

@property (nonatomic) UIImage *presetImage;

@end

@implementation UBSignatureDrawingViewController

#pragma mark - Init

- (instancetype)init
{
    return [self initWithImage:nil];
}

- (instancetype)initWithImage:(UIImage *)image
{
    if (self = [super initWithNibName:nil bundle:nil]) {
        _presetImage = image;
        _isEmpty = (!image);
        
        _model = [[UBSignatureDrawingModelAsync alloc] init];
    }
    
    return self;
}

#pragma mark - Public

- (void)reset
{
    [self.model reset];
    [self _updateViewFromModel];
}

- (UIImage *)fullSignatureImage
{
    return [self.model fullSignatureImage];
}

- (UIColor *)signatureColor
{
    return self.model.signatureColor;
}

- (void)setSignatureColor:(UIColor *)signatureColor
{
    self.model.signatureColor = signatureColor;
    self.bezierPathLayer.strokeColor = self.signatureColor.CGColor;
    self.bezierPathLayer.fillColor = self.signatureColor.CGColor;
}

- (void)setIsEmpty:(BOOL)isEmpty
{
    if (self.isEmpty == isEmpty) {
        return;
    }
    
    _isEmpty = isEmpty;
    
    if ([self.delegate respondsToSelector:@selector(signatureDrawingViewController:isEmptyDidChange:)]) {
        [self.delegate signatureDrawingViewController:self isEmptyDidChange:self.isEmpty];
    }
}

#pragma mark - UIViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    
    self.imageView = [[UIImageView alloc] init];
    [self.view addSubview:self.imageView];
    
    self.bezierPathLayer = ({
        CAShapeLayer *layer = [[CAShapeLayer alloc] init];
        layer.strokeColor = self.signatureColor.CGColor;
        layer.fillColor = self.signatureColor.CGColor;
        layer;
    });
    [self.view.layer addSublayer:self.bezierPathLayer];
    
    // Constraints
    self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addConstraints:@[
                           [NSLayoutConstraint constraintWithItem:self.imageView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeTop multiplier:1 constant:0],
                           [NSLayoutConstraint constraintWithItem:self.imageView attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeBottom multiplier:1 constant:0],
                           [NSLayoutConstraint constraintWithItem:self.imageView attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeLeft multiplier:1 constant:0],
                           [NSLayoutConstraint constraintWithItem:self.imageView attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeRight multiplier:1 constant:0]
                           ]];
    
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    if (self.presetImage) {
        [self.view layoutIfNeeded];
        [self.model addImageToSignature:self.presetImage];
        [self _updateViewFromModel];
        
        self.presetImage = nil;
    }
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    
    self.model.imageSize = self.view.bounds.size;
    [self _updateViewFromModel];
}

#pragma mark - UIResponder

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [super touchesBegan:touches withEvent:event];
    
    [self _updateModelWithTouches:touches event:event endContinuousLine:YES];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [super touchesMoved:touches withEvent:event];
    
    [self _updateModelWithTouches:touches event:event endContinuousLine:NO];
}

#pragma mark - Private

- (void)_updateModelWithTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event endContinuousLine:(BOOL)endContinuousLine
{
    NSMutableSet<UITouch *> *const coalescedTouches = [NSMutableSet new];
    for (UITouch *touch in touches) {
        // Get high fidelity (i.e. paired Apple stylus) touches on devices that support it.
        // https://apple.co/2E32vNk
        [coalescedTouches addObjectsFromArray:[event coalescedTouchesForTouch:touch]];
    }
    if (coalescedTouches.count > 0) {
        static NSArray<NSSortDescriptor *> *descriptors = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            descriptors = @[[NSSortDescriptor sortDescriptorWithKey:NSStringFromSelector(@selector(timestamp)) ascending:YES]];
        });
        NSArray<UITouch *> *const sortedCoalescedTouches = [coalescedTouches sortedArrayUsingDescriptors:descriptors];
        [sortedCoalescedTouches enumerateObjectsUsingBlock:^(UITouch * _Nonnull touch, NSUInteger idx, BOOL * _Nonnull stop) {
            [self _updateModelWithTouch:touch usePreciseLocation:YES endContinuousLine:endContinuousLine && idx == sortedCoalescedTouches.count - 1];
        }];
    } else {
        [self _updateModelWithTouch:[touches anyObject] usePreciseLocation:NO endContinuousLine:endContinuousLine];
    }
}

- (void)_updateModelWithTouch:(UITouch *)touch usePreciseLocation:(BOOL)usePreciseLocation endContinuousLine:(BOOL)endContinuousLine
{
    CGPoint touchPoint = [self.class _touchPointFromTouch:touch usePreciseLocation:usePreciseLocation];
    
    if (endContinuousLine) {
        [self.model asyncEndContinuousLine];
    }
    [self.model asyncUpdateWithPoint:touchPoint];
    
    [self _updateViewFromModel];
}

- (void)_updateViewFromModel
{
    [self.model asyncGetOutputWithBlock:^(UIImage *signatureImage, UIBezierPath *temporarySignatureBezierPath) {
        if (self.imageView.image != signatureImage) {
            self.imageView.image = signatureImage;
        }
        if (!CGPathEqualToPath(self.bezierPathLayer.path, temporarySignatureBezierPath.CGPath)) {
            self.bezierPathLayer.path = temporarySignatureBezierPath.CGPath;
        }
        
        self.isEmpty = (self.bezierPathLayer.path == nil && self.imageView.image == nil);
    }];
}

#pragma mark - Helpers

+ (CGPoint)_touchPointFromTouch:(UITouch *)touch usePreciseLocation:(BOOL)usePreciseLocation
{
    CGPoint point;
    if (usePreciseLocation) {
        // Use precise location for touches captured with paired Apple styluses.
        // https://apple.co/2GzmDrX
        point = [touch preciseLocationInView:touch.view];
    } else {
        point = [touch locationInView:touch.view];
    }
    
    return point;
}

@end

//
//  XBFilteredVideoView.m
//  XBImageFilters
//
//  Created by xissburg on 5/19/13.
//
//

#import "XBFilteredVideoView.h"
#import <AVFoundation/AVFoundation.h>

@interface XBFilteredVideoView ()

@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) AVURLAsset *asset;
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *videoTrackOutput;
@property (assign, nonatomic) size_t videoWidth, videoHeight;
@property (assign, nonatomic) CVOpenGLESTextureCacheRef videoTextureCache;
@property (assign, nonatomic) CVOpenGLESTextureRef videoMainTexture;
@property (assign, nonatomic) BOOL playWhenReady;

@property (strong, nonatomic) AVAssetWriter *assetWriter;
@property (strong, nonatomic) AVAssetWriterInput *writerInput;
@property (strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *writerPixelBufferAdaptor;

@end

@implementation XBFilteredVideoView

- (void)_XBFilteredVideoViewInit
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_6_0
    CVReturn ret = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, self.context, NULL, &_videoTextureCache);
#else
    CVReturn ret = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, (__bridge void *)self.context, NULL, &_videoTextureCache);
#endif
    if (ret != kCVReturnSuccess) {
        NSLog(@"Error at CVOpenGLESTextureCacheCreate: %d", ret);
    }
}

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        [self _XBFilteredVideoViewInit];
    }
    return self;
}

- (void)awakeFromNib
{
    [super awakeFromNib];
    [self _XBFilteredVideoViewInit];
}

- (void)dealloc
{
    [self stop];
}

- (void)setVideoURL:(NSURL *)videoURL
{
    if (videoURL == _videoURL) {
        return;
    }
    _videoURL = [videoURL copy];
    
    self.asset = [AVURLAsset assetWithURL:videoURL];
    
    void (^block)(void) = ^{
        NSError *error = nil;
        if ([self.asset statusOfValueForKey:@"tracks" error:&error] != AVKeyValueStatusLoaded) {
            NSLog(@"Failed to load tracks: %@", error);
            return;
        }
        
        [self createAssetReader];
        
        if (self.playWhenReady) {
            [self play];
        }
    };
    
    NSError *error = nil;
    if ([self.asset statusOfValueForKey:@"tracks" error:&error] == AVKeyValueStatusLoaded) {
        block();
    }
    else {
        [self.asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), block);
        }];
    }
}

- (void)createAssetReader
{
    AVAssetTrack *videoTrack = [self.asset tracksWithMediaType:AVMediaTypeVideo][0];
    id outputSettings = @{(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    self.videoTrackOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettings];
    self.videoTrackOutput.alwaysCopiesSampleData = NO;/*
    self.videoWidth = videoTrack.naturalSize.width;
    self.videoHeight = videoTrack.naturalSize.height;*/
    
    CGAffineTransform t = videoTrack.preferredTransform;
    GLKMatrix4 r = GLKMatrix4Make(t.a, t.b, 0, 0, t.c, t.d, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1);
    GLKMatrix4 s = GLKMatrix4MakeScale(1, -1, 1);
    self.contentTransform = GLKMatrix4Multiply(s, r);
    
    NSError *error = nil;
    self.assetReader = [[AVAssetReader alloc] initWithAsset:self.asset error:&error];
    if (self.assetReader == nil) {
        NSLog(@"Failed to initialize AssetReader: %@", error);
        return;
    }
    [self.assetReader addOutput:self.videoTrackOutput];
    
    if (![self.assetReader startReading]) {
        NSLog(@"Failed to start reading from asset: %@", self.assetReader.error);
        return;
    }
}

- (void)play
{
    if (self.assetReader.status != AVAssetReaderStatusReading) {
        self.playWhenReady = YES;
        return;
    }
    
    [self.displayLink invalidate];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(draw:)];
    self.displayLink.frameInterval = 2;
    [self.displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)pause
{
    self.displayLink.paused = YES;
}

- (void)stop
{
    self.playWhenReady = NO;
    [self.assetReader cancelReading];
    CADisplayLink *displayLink = self.displayLink;
    self.displayLink = nil;
    [displayLink invalidate];
}

- (void)cleanUpTextures
{
    if (self.videoMainTexture != NULL) {
        CFRelease(self.videoMainTexture);
        self.videoMainTexture = NULL;
    }
    
    CVOpenGLESTextureCacheFlush(self.videoTextureCache, 0);
}

- (void)draw:(CADisplayLink *)displayLink
{
    if (self.assetReader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sampleBuffer = [self.videoTrackOutput copyNextSampleBuffer];
        if (sampleBuffer) {
            [EAGLContext setCurrentContext:self.context];
            
            [self cleanUpTextures];
            CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            // Compensate for padding. A small black line will be visible on the right. Also adjust the texture coordinate transform to fix this.
            size_t width = CVPixelBufferGetBytesPerRow(imageBuffer)/4;
            size_t height = CVPixelBufferGetHeight(imageBuffer);
            
            if (width != self.videoWidth || height != self.videoHeight) {
                self.videoWidth = width;
                self.videoHeight = height;
                self.contentSize = CGSizeMake(width, height);
                float ratio = (float)CVPixelBufferGetWidth(imageBuffer)/width;
                self.texCoordTransform = (GLKMatrix2){ratio, 0, 0, 1}; // Apply a horizontal stretch to hide the row padding
            }
            
            [self _setTextureDataWithTextureCache:self.videoTextureCache texture:&_videoMainTexture imageBuffer:imageBuffer];
            [self display];
            
            CMSampleBufferInvalidate(sampleBuffer);
            CFRelease(sampleBuffer);
        }
        else {
            [self stop];
            
            if (self.replay) {
                [self createAssetReader];
                [self play];
            }
        }
    }
    else {
        [self stop];
        if (self.assetReader.status == AVAssetReaderStatusFailed) {
            NSLog(@"%@", self.assetReader.error);
        }
    }
}

- (BOOL)saveFilteredVideoToURL:(NSURL *)URL error:(NSError **)error completion:(void (^)(void))completion
{
    self.assetWriter = [[AVAssetWriter alloc] initWithURL:URL fileType:AVFileTypeQuickTimeMovie error:error];
    if (self.assetWriter == nil) {
        return NO;
    }
    
    self.assetWriter.movieFragmentInterval = CMTimeMakeWithSeconds(1.0, 1000);
    id outputSettings = @{AVVideoCodecKey: AVVideoCodecH264, AVVideoWidthKey: @(self.videoWidth), AVVideoHeightKey: @(self.videoHeight)};
    self.writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:outputSettings];
    self.writerInput.expectsMediaDataInRealTime = NO;
    [self.assetWriter addInput:self.writerInput];
    
    id pixelBufferAttributes = @{(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (__bridge NSString *)kCVPixelBufferWidthKey: @(self.videoWidth), (__bridge NSString *)kCVPixelBufferHeightKey: @(self.videoHeight)};
    self.writerPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.writerInput sourcePixelBufferAttributes:pixelBufferAttributes];
    
    if (![self.assetWriter startWriting]) {
        if (error != NULL) {
            *error = self.assetWriter.error;
        }
        return NO;
    }
    
    [self stop];
    [self createAssetReader];
    [self.assetWriter startSessionAtSourceTime:kCMTimeZero];
    
    CVOpenGLESTextureCacheRef textureCache;
    
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_6_0
    CVReturn ret = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, self.context, NULL, &textureCache);
#else
    CVReturn ret = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, (__bridge void *)self.context, NULL, &textureCache);
#endif
    if (ret != kCVReturnSuccess) {
        NSLog(@"Error at CVOpenGLESTextureCacheCreate: %d", ret);
        return NO;
    }
    
    CVPixelBufferRef pixelBuffer;
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.writerPixelBufferAdaptor.pixelBufferPool, &pixelBuffer);
    
    CVOpenGLESTextureRef textureTarget;
    CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, NULL, GL_TEXTURE_2D, GL_RGBA, self.videoWidth, self.videoHeight, GL_BGRA, GL_UNSIGNED_BYTE, 0, &textureTarget);
    glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(textureTarget));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    GLuint framebuffer;
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, CVOpenGLESTextureGetName(textureTarget), 0);
    
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"Failed to create framebuffer: %x", status);
        return NO;
    }
    
    [self.writerInput requestMediaDataWhenReadyOnQueue:dispatch_get_main_queue() usingBlock:^{
        if (self.assetReader.status == AVAssetReaderStatusReading) {
            CMSampleBufferRef sampleBuffer = [self.videoTrackOutput copyNextSampleBuffer];
            if (sampleBuffer) {
                [EAGLContext setCurrentContext:self.context];
                [self cleanUpTextures];
                
                CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                // Compensate for padding. A small black line will be visible on the right. Also adjust the texture coordinate transform to fix this.
                size_t width = CVPixelBufferGetBytesPerRow(imageBuffer)/4;
                size_t height = CVPixelBufferGetHeight(imageBuffer);
                
                if (width != self.videoWidth || height != self.videoHeight) {
                    self.videoWidth = width;
                    self.videoHeight = height;
                    self.contentSize = CGSizeMake(width, height);
                    float ratio = (float)CVPixelBufferGetWidth(imageBuffer)/width;
                    self.texCoordTransform = (GLKMatrix2){ratio, 0, 0, 1}; // Apply a horizontal stretch to hide the row padding
                }
                
                [self _setTextureDataWithTextureCache:self.videoTextureCache texture:&_videoMainTexture imageBuffer:imageBuffer];
                [self displayWithFramebuffer:framebuffer width:width height:height present:NO];
                
                CMTime presentationTimeStamp = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);
                if (![self.writerPixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:presentationTimeStamp]) {
                    NSLog(@"Failed to append pixel buffer at time %lld", presentationTimeStamp.value);
                }
                
                CMSampleBufferInvalidate(sampleBuffer);
                CFRelease(sampleBuffer);
            }
            else {
                [self.writerInput markAsFinished];
            }
        }
        else if (self.assetReader.status == AVAssetReaderStatusCompleted) {
            glDeleteFramebuffers(1, &framebuffer);
            
            if (completion) {
                completion();
            }
            
            self.assetWriter = nil;
            self.writerInput = nil;
            self.writerPixelBufferAdaptor = nil;
        }
    }];
    
    return YES;
}

@end

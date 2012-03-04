//
//  WindowController.m
//  Perpetual
//
//  Created by Bryan Veloso on 2/27/12.
//  Copyright (c) 2012 Revyver, Inc. All rights reserved.
//

#import "WindowController.h"

#import "AppDelegate.h"
#import "INAppStoreWindow.h"
#import "NSString+TimeConversion.h"
#import "PlaybackController.h"
#import "Track.h"

#import <AVFoundation/AVFoundation.h>
#import <WebKit/WebKit.h>

NSString *const WindowControllerHTMLImagePlaceholder = @"{{ image_url }}";
NSString *const RangeDidChangeNotification = @"com.revyver.perpetual.RangeDidChangeNotification";

@interface WindowController () <NSWindowDelegate>
@property (nonatomic, strong) PlaybackController *playbackController;

- (void)composeInterface;
- (void)layoutTitleBarSegmentedControls;
- (void)layoutTitleBarWindowResizeControls;
- (void)layoutWebView;
- (void)layoutInitialInterface:(id)sender;
- (void)updateVolumeSlider;
@end

@implementation WindowController

@synthesize playbackController = _playbackController;

// Window
@synthesize collapsed = _collapsed;

// Cover and Statistics Display
@synthesize webView = _webView;

// Track Metadata Displays
@synthesize trackTitle = _trackTitle;
@synthesize trackSubtitle = _trackSubtitle;
@synthesize currentTime = _currentTime;
@synthesize rangeTime = _rangeTime;

// Sliders and Progress Bar
@synthesize startSlider = _startSlider;
@synthesize endSlider = _endSlider;
@synthesize progressBar = _progressBar;

// Lower Toolbar
@synthesize open = _openFile;
@synthesize play = _play;
@synthesize volumeControl = _volumeControl;
@synthesize loopCountLabel = _loopCountLabel;
@synthesize loopCountStepper = _loopCountStepper;

- (id)init
{
	return [super initWithWindowNibName:@"Window"];
}

- (void)windowDidLoad
{
    [super windowDidLoad];
    [[self window] setAllowsConcurrentViewDrawing:YES];

    // Register notifications for our playback services.
    // [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackDidStart:) name:PlaybackDidStartNotification object:nil];
    // [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackDidStop:) name:PlaybackDidStopNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackHasProgressed:) name:PlaybackHasProgressedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(trackLoopCountChanged:) name:TrackLoopCountChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(trackWasLoaded:) name:TrackWasLoadedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(rangeDidChange:) name:RangeDidChangeNotification object:nil];

    [self composeInterface];
}

#pragma mark Window Compositioning

- (void)composeInterface
{
    // Customize INAppStoreWindow.
    INAppStoreWindow *window = (INAppStoreWindow *)[self window];
    window.titleBarHeight = 40.f;
    window.trafficLightButtonsLeftMargin = 7.f;
    // window.backgroundColor

    [self layoutTitleBarSegmentedControls];
    [self layoutTitleBarWindowResizeControls];
    [self layoutWebView];

    // Load our blank cover, since we obviously have no audio to play.
    [self layoutCoverArtWithIdentifier:@"cover.jpg"];
}

- (void)layoutTitleBarSegmentedControls
{
    // - NOOP -
    // Implements a very crude NSSegmentedControl, used to switch between the
    // album view of the track currently opened and the listening statistics
    // for that track.
    INAppStoreWindow *window = (INAppStoreWindow *)[self window];
    NSView *titleBarView = [window titleBarView];
    NSSize controlSize = NSMakeSize(64.f, 32.f);
    NSRect controlFrame = NSMakeRect(NSMidX(titleBarView.bounds) - (controlSize.width / 2.f),
                                     NSMidY(titleBarView.bounds) - 17.0f,
                                     controlSize.width,
                                     controlSize.height);
    NSSegmentedControl *switcher = [[NSSegmentedControl alloc] initWithFrame:controlFrame];
    [switcher setSegmentCount:2];
    [switcher setSegmentStyle:NSSegmentStyleTexturedRounded];
    [switcher setImage:[NSImage imageNamed:@"MusicNoteTemplate"] forSegment:0];
    [switcher setImage:[NSImage imageNamed:@"InfinityTemplate"] forSegment:1];
    [switcher setSelectedSegment:0];
    [switcher setEnabled:FALSE forSegment:1]; // Disables the statistics segment.
    [switcher setAutoresizingMask:NSViewMinXMargin|NSViewMaxXMargin|NSViewMinYMargin|NSViewMaxYMargin];
    [[switcher cell] setTrackingMode:NSSegmentSwitchTrackingSelectOne];
    [titleBarView addSubview:switcher];
}

- (void)layoutTitleBarWindowResizeControls
{
    self.collapsed = NO;

    INAppStoreWindow *window = (INAppStoreWindow *)[self window];
    NSView *titleBarView = [window titleBarView];
    NSSize controlSize = NSMakeSize(16.f, 16.f);
    NSRect controlFrame = NSMakeRect(NSMaxX(titleBarView.bounds) - (controlSize.width + 7.f),
                                     NSMidY(titleBarView.bounds) - (controlSize.height / 2.f),
                                     controlSize.width,
                                     controlSize.height);
    NSButton *resizer = [[NSButton alloc] initWithFrame:controlFrame];
    [resizer setAction:@selector(toggleWindowHeight:)];
    [resizer setAutoresizingMask:NSViewMinXMargin];
    [resizer setBezelStyle:NSTexturedSquareBezelStyle];
    [resizer setBordered:FALSE];
    [resizer setButtonType:NSToggleButton];
    [resizer setImage:[NSImage imageNamed:@"InfinityTemplate"]];
    [titleBarView addSubview:resizer];
}

- (void)layoutWebView
{
    // Set us up as the delegate of the WebView for relevant events.
    // UIDelegate and FrameLoadDelegate are set in Interface Builder.
    [[self webView] setEditingDelegate:self];
}

- (void)layoutInitialInterface:(Track *)track
{
    // Compose the initial user interface.
    // Set the max value of the progress bar to the duration of the track.
    self.progressBar.maxValue = track.duration;

    // Set the slider attributes.
    self.startSlider.maxValue = track.duration;
    self.startSlider.floatValue = 0.f;
    self.startSlider.numberOfTickMarks = track.duration;
    self.endSlider.maxValue = track.duration;
    self.endSlider.floatValue = track.duration;
    self.endSlider.numberOfTickMarks = track.duration;

    // Set the track title, artist, and album using the derived metadata.
    self.trackTitle.stringValue = track.title;
    self.trackSubtitle.stringValue = [NSString stringWithFormat:@"%@ / %@", track.albumName, track.artist];

    // Fill in rangeTime with the difference between the two slider's values.
    // Until we start saving people's slider positions, this will always
    // equal the duration of the song at launch.
    NSTimeInterval rangeValue = self.endSlider.doubleValue - self.startSlider.doubleValue;
    self.rangeTime.stringValue = [NSString convertIntervalToMinutesAndSeconds:rangeValue];

    // Load the cover art using the derived data URI.
    [self layoutCoverArtWithIdentifier:[track.imageDataURI absoluteString]];
}


- (void)layoutCoverArtWithIdentifier:(NSString *)identifier
{
    NSURL *htmlFileURL = [[NSBundle mainBundle] URLForResource:@"cover" withExtension:@"html"];
    NSError *err = nil;
    NSMutableString *html = [NSMutableString stringWithContentsOfURL:htmlFileURL encoding:NSUTF8StringEncoding error:&err];
    if (html == nil) {
        // Do something with the error.
        NSLog(@"%@", err);
        return;
    }

    [html replaceOccurrencesOfString:WindowControllerHTMLImagePlaceholder withString:identifier options:0 range:NSMakeRange(0, html.length)];
    [self.webView.mainFrame loadHTMLString:html baseURL:[[NSBundle mainBundle] resourceURL]];
}

- (void)updateVolumeSlider
{
    float volume = [[AppDelegate sharedInstance].playbackController.track.asset volume];
    [self.volumeControl setFloatValue:volume];
}


#pragma mark Notification Observers

- (void)playbackHasProgressed:(NSNotification *)notification
{
    PlaybackController *object = [notification object];
    if ([object isKindOfClass:[PlaybackController class]]) {
        self.currentTime.stringValue = [NSString convertIntervalToMinutesAndSeconds:object.track.asset.currentTime];
        self.progressBar.floatValue = object.track.asset.currentTime;
    }
}

- (void)rangeDidChange:(NSNotification *)notification
{
    WindowController *object = [notification object];
    NSTimeInterval rangeValue = object.endSlider.doubleValue - object.startSlider.doubleValue;
    self.rangeTime.stringValue = [NSString convertIntervalToMinutesAndSeconds:rangeValue];
}

- (void)trackLoopCountChanged:(NSNotification *)notification
{
    PlaybackController *object = [notification object];
    if ([object isKindOfClass:[PlaybackController class]]) {
        // Update the labels.
        if (object.loopCount < object.loopInfiniteCount) {
            [self.loopCountLabel setStringValue:[NSString stringWithFormat:@"x%d", object.loopCount]];
        }
        else {
            [self.loopCountLabel setStringValue:@"∞"];
        }

        // Finally, update the stepper so it's snychronized.
        [self.loopCountStepper setIntegerValue:object.loopCount];
    }
}

- (void)trackWasLoaded:(NSNotification *)notification
{
    PlaybackController *object = [notification object];
    if ([object isKindOfClass:[PlaybackController class]]) {
        [self layoutInitialInterface:[object track]];
        [self showWindow:self];
        [self.play setEnabled:TRUE];
    }
}


#pragma mark IBAction Methods

- (IBAction)handlePlayState:(id)sender
{
    PlaybackController *playbackController = [AppDelegate sharedInstance].playbackController;
    if (playbackController.track.asset.playing) {
        [playbackController stop];
    }
    else {
        [playbackController play];
    }
}

- (IBAction)incrementLoopCount:(id)sender
{
    [[AppDelegate sharedInstance].playbackController updateLoopCount:[self.loopCountStepper intValue]];
}

- (IBAction)setFloatForStartSlider:(id)sender
{
    PlaybackController *playbackController = [AppDelegate sharedInstance].playbackController;
    if (self.startSlider.doubleValue > playbackController.track.endTime) {
        playbackController.track.startTime = self.startSlider.doubleValue;
    }
    else {
        self.startSlider.doubleValue = playbackController.track.startTime;
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:RangeDidChangeNotification object:self userInfo:nil];
}

- (IBAction)setFloatForEndSlider:(id)sender
{
    PlaybackController *playbackController = [AppDelegate sharedInstance].playbackController;
    if (self.endSlider.doubleValue > playbackController.track.startTime) {
        playbackController.track.endTime = self.endSlider.doubleValue;
    }
    else {
        self.endSlider.doubleValue = playbackController.track.startTime;
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:RangeDidChangeNotification object:self userInfo:nil];
}

- (IBAction)setTimeForCurrentTime:(id)sender
{
    NSTimeInterval interval = self.progressBar.doubleValue;
    AVAudioPlayer *asset = [AppDelegate sharedInstance].playbackController.track.asset;
    asset.currentTime = interval;
}

- (IBAction)setFloatForVolume:(id)sender
{
    float newValue = [sender floatValue];
    [[AppDelegate sharedInstance].playbackController.track.asset setVolume:newValue];
    [self updateVolumeSlider];
}

- (IBAction)toggleWindowHeight:(id)sender
{
    float delta = 250.f;
    NSRect window = [self.window frame];
    NSRect webView = [self.webView frame];

    if (!self.collapsed) {
        window.origin.y += delta;
        window.size.height -= delta;
        webView.origin.y += delta;
        self.collapsed = YES;
    }
    else {
        window.origin.y -= delta;
        window.size.height += delta;
        webView.origin.y -= delta;
        self.collapsed = NO;
    }
    [self.webView setFrame:webView];
    [self.window setFrame:window display:YES animate:YES];
}


#pragma mark NSWindow Delegate Methods

- (NSRect)window:(NSWindow *)window willPositionSheet:(NSWindow *)sheet usingRect:(NSRect)rect
{
    return NSOffsetRect(NSInsetRect(rect, 8, 0), 0, -18);
}


#pragma mark WebView Delegate Methods

- (NSUInteger)webView:(WebView *)webView dragDestinationActionMaskForDraggingInfo:(id<NSDraggingInfo>)draggingInfo
{
    return WebDragDestinationActionNone; // We shouldn't be able to drag things into the webView.
}

- (NSUInteger)webView:(WebView *)webView dragSourceActionMaskForPoint:(NSPoint)point
{
    return WebDragSourceActionNone; // We shouldn't be able to drag the artwork out of the webView.
}

- (NSArray *)webView:(WebView *)sender contextMenuItemsForElement:(NSDictionary *)element defaultMenuItems:(NSArray *)defaultMenuItems
{
    return nil; // Disable the webView's contextual menu.
}

- (BOOL)webView:(WebView *)webView shouldChangeSelectedDOMRange:(DOMRange *)currentRange toDOMRange:(DOMRange *)proposedRange affinity:(NSSelectionAffinity)selectionAffinity stillSelecting:(BOOL)flag
{
    return NO; // Prevent the selection of content.
}

@end

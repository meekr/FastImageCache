//
//  FICDViewController.m
//  FastImageCacheDemo
//
//  Copyright (c) 2013 Path, Inc.
//  See LICENSE for full license agreement.
//

#import "FICDViewController.h"
#import "FICImageCache.h"
#import "FICDTableView.h"
#import "FICDAppDelegate.h"
#import "FICDPhoto.h"
#import "FICDFullscreenPhotoDisplayController.h"
#import "FICDPhotosTableViewCell.h"

#pragma mark Class Extension

@interface FICDViewController () <UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate, FICDPhotosTableViewCellDelegate, FICDFullscreenPhotoDisplayControllerDelegate> {
    FICDTableView *_tableView;
    NSArray *_photos;
    BOOL _usesImageTable;
    BOOL _reloadTableViewAfterScrollingAnimationEnds;
    BOOL _shouldResetData;
    NSInteger _selectedSegmentControlIndex;
    NSInteger _callbackCount;
    UIAlertView *_noImagesAlertView;
    UILabel *_averageFPSLabel;
}

@end

#pragma mark

@implementation FICDViewController

#pragma mark - Object Lifecycle

- (id)init {
    self = [super init];
    
    if (self != nil) {
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSArray *imageURLs = [mainBundle URLsForResourcesWithExtension:@"jpg" subdirectory:@"Demo Images"];
        
        if ([imageURLs count] > 0) {
            NSMutableArray *photos = [[NSMutableArray alloc] init];
            for (NSURL *imageURL in imageURLs) {
                FICDPhoto *photo = [[FICDPhoto alloc] init];
                [photo setSourceImageURL:imageURL];
                [photos addObject:photo];
                [photo release];
            }
            
            while ([photos count] < 5000) {
                [photos addObjectsFromArray:photos]; // Create lots of photos to scroll through
            }
            
            _photos = photos;
        } else {
            NSString *title = @"No Source Images";
            NSString *message = @"There are no JPEG images in the Demo Images folder. Please run the fetch_demo_images.sh script, or add your own JPEG images to this folder before running the demo app.";
            _noImagesAlertView = [[UIAlertView alloc] initWithTitle:title message:message delegate:self cancelButtonTitle:@"OK" otherButtonTitles:nil];
            [_noImagesAlertView show];
        }
    }
    
    return self;
}

- (void)dealloc {
    [_tableView setDelegate:nil];
    [_tableView setDataSource:nil];
    [_tableView release];
    
    [_photos release];
    
    [_noImagesAlertView setDelegate:nil];
    [_noImagesAlertView release];
    
    [_averageFPSLabel release];
 
    [super dealloc];
}

#pragma mark - View Controller Lifecycle

- (void)loadView {
    CGRect viewFrame = [[UIScreen mainScreen] bounds];
    UIView *view = [[[UIView alloc] initWithFrame:viewFrame] autorelease];
    [view setAutoresizingMask:(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight)];
    [view setBackgroundColor:[UIColor whiteColor]];
    
    [self setView:view];
    
    // Configure the table view
    if (_tableView == nil) {
        _tableView = [[FICDTableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        [_tableView setDataSource:self];
        [_tableView setDelegate:self];
        [_tableView setAutoresizingMask:(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight)];
        [_tableView setSeparatorStyle:UITableViewCellSeparatorStyleNone];
        
        CGFloat tableViewCellOuterPadding = [FICDPhotosTableViewCell outerPadding];
        [_tableView setContentInset:UIEdgeInsetsMake(0, 0, tableViewCellOuterPadding, 0)];
        
        if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
            [_tableView setScrollIndicatorInsets:UIEdgeInsetsMake(7, 0, 7, 1)];
        }
    }
    
    [_tableView setFrame:[view bounds]];
    [view addSubview:_tableView];
    
    // Configure the navigation item
    UINavigationItem *navigationItem = [self navigationItem];
    
    UIBarButtonItem *resetBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Reset" style:UIBarButtonItemStyleBordered target:self action:@selector(_reset)] autorelease];
    [navigationItem setLeftBarButtonItem:resetBarButtonItem];
    
    UISegmentedControl *segmentedControl = [[[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:@"Conventional", @"Image Table", nil]] autorelease];
    [segmentedControl setSelectedSegmentIndex:0];
    [segmentedControl addTarget:self action:@selector(_segmentedControlValueChanged:) forControlEvents:UIControlEventValueChanged];
    [segmentedControl setSegmentedControlStyle:UISegmentedControlStyleBar];
    [segmentedControl sizeToFit];
    [navigationItem setTitleView:segmentedControl];
    
    // Configure the average FPS label
    if (_averageFPSLabel == nil) {
        _averageFPSLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 54, 22)];
        [_averageFPSLabel setBackgroundColor:[UIColor clearColor]];
        [_averageFPSLabel setFont:[UIFont boldSystemFontOfSize:16]];
        [_averageFPSLabel setTextAlignment:NSTextAlignmentRight];
        
        [_tableView addObserver:self forKeyPath:@"averageFPS" options:NSKeyValueObservingOptionNew context:NULL];
    }
    
    UIBarButtonItem *averageFPSLabelBarButtonItem = [[[UIBarButtonItem alloc] initWithCustomView:_averageFPSLabel] autorelease];
    [navigationItem setRightBarButtonItem:averageFPSLabelBarButtonItem];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    [[FICDFullscreenPhotoDisplayController sharedDisplayController] setDelegate:self];
    [self reloadTableViewAndScrollToTop:YES];
}

#pragma mark - Reloading Data

- (void)reloadTableViewAndScrollToTop:(BOOL)scrollToTop {
    UIApplication *sharedApplication = [UIApplication sharedApplication];
    
    // Don't allow interaction events to interfere with thumbnail generation
    if ([sharedApplication isIgnoringInteractionEvents] == NO) {
        [sharedApplication beginIgnoringInteractionEvents];
    }

    if (scrollToTop) {
        // If the table view isn't already scrolled to top, we do that now, deferring the actual table view reloading logic until the animation finishes.
        CGFloat tableViewTopmostContentOffsetY = 0;
        CGFloat tableViewCurrentContentOffsetY = [_tableView contentOffset].y;
        
        if ([self respondsToSelector:@selector(topLayoutGuide)]) {
            id <UILayoutSupport> topLayoutGuide = [self topLayoutGuide];
            tableViewTopmostContentOffsetY = -[topLayoutGuide length];
        }
        
        if (tableViewCurrentContentOffsetY > tableViewTopmostContentOffsetY) {
            [_tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0] atScrollPosition:UITableViewScrollPositionTop animated:YES];
            
            _reloadTableViewAfterScrollingAnimationEnds = YES;
        }
    }
    
    if (_reloadTableViewAfterScrollingAnimationEnds == NO) {
        // Reset the data now
        if (_shouldResetData) {
            _shouldResetData = NO;
            [[FICImageCache sharedImageCache] reset];
            
            // Delete all cached thumbnail images as well
            for (FICDPhoto *photo in _photos) {
                [photo deleteThumbnail];
            }
        }
        
        _usesImageTable = _selectedSegmentControlIndex == 1;
        
        dispatch_block_t tableViewReloadBlock = ^{
            [_tableView reloadData];
            [_tableView resetScrollingPerformanceCounters];
            
            if ([_tableView isHidden]) {
                [[_tableView layer] addAnimation:[CATransition animation] forKey:kCATransition];
            }
            
            [_tableView setHidden:NO];
            
            // Re-enable interaction events once every thumbnail has been generated
            if ([sharedApplication isIgnoringInteractionEvents]) {
                [sharedApplication endIgnoringInteractionEvents];
            }
        };
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            // In order to make a fair comparison for both methods, we ensure that the cached data is ready to go before updating the UI.
            if (_usesImageTable) {
                _callbackCount = 0;
                NSSet *uniquePhotos = [NSSet setWithArray:_photos];
                for (FICDPhoto *photo in uniquePhotos) {
                    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
                    FICImageCache *sharedImageCache = [FICImageCache sharedImageCache];
                    
                    if ([sharedImageCache imageExistsForEntity:photo withFormatName:FICDPhotoSquareImageFormatName] == NO) {
                        if (_callbackCount == 0) {
                            NSLog(@"*** FIC Demo: Fast Image Cache: Generating thumbnails...");
                            
                            // Hide the table view's contents while we generate new thumbnails
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [_tableView setHidden:YES];
                                [[_tableView layer] addAnimation:[CATransition animation] forKey:kCATransition];
                            });
                        }
                        
                        _callbackCount++;
                        
                        [sharedImageCache asynchronouslyRetrieveImageForEntity:photo withFormatName:FICDPhotoSquareImageFormatName completionBlock:^(id<FICEntity> entity, NSString *formatName, UIImage *image) {
                            _callbackCount--;
                            
                            if (_callbackCount == 0) {
                                NSLog(@"*** FIC Demo: Fast Image Cache: Generated thumbnails in %g seconds", CFAbsoluteTimeGetCurrent() - startTime);
                                dispatch_async(dispatch_get_main_queue(), tableViewReloadBlock);
                            }
                        }];
                    }
                }
                
                if (_callbackCount == 0) {
                    dispatch_async(dispatch_get_main_queue(), tableViewReloadBlock);
                }
            } else {
                [self _generateConventionalThumbnails];
                
                dispatch_async(dispatch_get_main_queue(), tableViewReloadBlock);
            }
        });
    }
}

- (void)_reset {
    _shouldResetData = YES;
    
    [self reloadTableViewAndScrollToTop:YES];
}

- (void)_segmentedControlValueChanged:(UISegmentedControl *)segmentedControl {
    _selectedSegmentControlIndex = [segmentedControl selectedSegmentIndex];
    
    // If there's any scrolling momentum, we want to stop it now
    CGPoint tableViewContentOffset = [_tableView contentOffset];
    [_tableView setContentOffset:tableViewContentOffset animated:NO];
    
    [self reloadTableViewAndScrollToTop:NO];
}

#pragma mark - Image Helper Functions

static UIImage * _FICDColorAveragedImageFromImage(UIImage *image) {
    // Crop the image to the area occupied by the status bar
    CGSize imageSize = [image size];
    CGSize statusBarSize = [[UIApplication sharedApplication] statusBarFrame].size;
    CGRect cropRect = CGRectMake(0, 0, imageSize.width, statusBarSize.height);
    
    CGImageRef croppedImageRef = CGImageCreateWithImageInRect([image CGImage], cropRect);
    UIImage *statusBarImage = [UIImage imageWithCGImage:croppedImageRef];
    CGImageRelease(croppedImageRef);
    
    // Draw the cropped image into a 1x1 bitmap context; this automatically averages the color values of every pixel
    CGColorSpaceRef colorSpaceRef = CGColorSpaceCreateDeviceRGB();
    CGSize contextSize = CGSizeMake(1, 1);
    CGContextRef bitmapContextRef = CGBitmapContextCreate(NULL, contextSize.width, contextSize.height, 8, 0, colorSpaceRef, (kCGImageAlphaNoneSkipFirst & kCGBitmapAlphaInfoMask));
    CGContextSetInterpolationQuality(bitmapContextRef, kCGInterpolationMedium);
    
    CGRect drawRect = CGRectZero;
    drawRect.size = contextSize;
    
    UIGraphicsPushContext(bitmapContextRef);
    [statusBarImage drawInRect:drawRect];
    UIGraphicsPopContext();
    
    // Create an image from the bitmap context
    CGImageRef colorAveragedImageRef = CGBitmapContextCreateImage(bitmapContextRef);
    UIImage *colorAveragedImage = [UIImage imageWithCGImage:colorAveragedImageRef];
    CGImageRelease(colorAveragedImageRef);
    
    return colorAveragedImage;
}

static BOOL _FICDImageIsLight(UIImage *image) {
    BOOL imageIsLight = NO;
    
    CGImageRef imageRef = [image CGImage];
    CGDataProviderRef dataProviderRef = CGImageGetDataProvider(imageRef);
    NSData *pixelData = (NSData *)CGDataProviderCopyData(dataProviderRef);
    
    if ([pixelData length] > 0) {
        const UInt8 *pixelBytes = [pixelData bytes];
        
        // Whether or not the image format is opaque, the first byte is always the alpha component, followed by RGB.
        uint8_t pixelR = pixelBytes[1];
        uint8_t pixelG = pixelBytes[2];
        uint8_t pixelB = pixelBytes[3];
        
        // Calculate the perceived luminance of the pixel; the human eye favors green, followed by red, then blue.
        double percievedLuminance = 1 - (((0.299 * pixelR) + (0.587 * pixelG) + (0.114 * pixelB)) / 255);
        
        imageIsLight = percievedLuminance < 0.5;
    }
    
    return imageIsLight;
}

- (void)_updateStatusBarStyleForColorAveragedImage:(UIImage *)colorAveragedImage {
    BOOL imageIsLight = _FICDImageIsLight(colorAveragedImage);
    
    UIStatusBarStyle statusBarStyle = imageIsLight ? UIStatusBarStyleDefault : UIStatusBarStyleLightContent;
    [[UIApplication sharedApplication] setStatusBarStyle:statusBarStyle animated:YES];
}

#pragma mark - Working with Thumbnails

- (void)_generateConventionalThumbnails {
    BOOL neededToGenerateThumbnail = NO;
    CFAbsoluteTime startTime = 0;
    
    NSSet *uniquePhotos = [NSSet setWithArray:_photos];
    for (FICDPhoto *photo in uniquePhotos) {
        if ([photo thumbnailImageExists] == NO) {
            if (neededToGenerateThumbnail == NO) {
                NSLog(@"*** FIC Demo: Conventional Method: Generating thumbnails...");
                startTime = CFAbsoluteTimeGetCurrent();
                
                neededToGenerateThumbnail = YES;
                
                // Hide the table view's contents while we generate new thumbnails
                dispatch_async(dispatch_get_main_queue(), ^{
                    [_tableView setHidden:YES];
                    [[_tableView layer] addAnimation:[CATransition animation] forKey:kCATransition];
                });
            }
            
            @autoreleasepool {
                [photo generateThumbnail];
            }
        }
    }
    
    if (neededToGenerateThumbnail) {
        NSLog(@"*** FIC Demo: Conventional Method: Generated thumbnails in %g seconds", CFAbsoluteTimeGetCurrent() - startTime);
    }
}

#pragma mark - Displaying the Average Framerate

- (void)_displayAverageFPS:(CGFloat)averageFPS {
    if ([_averageFPSLabel attributedText] == nil) {
        CATransition *fadeTransition = [CATransition animation];
        [[_averageFPSLabel layer] addAnimation:fadeTransition forKey:kCATransition];
    }
    
    NSString *averageFPSString = [NSString stringWithFormat:@"%.0f", averageFPS];
    NSUInteger averageFPSStringLength = [averageFPSString length];
    NSString *displayString = [NSString stringWithFormat:@"%@ FPS", averageFPSString];
    
    UIColor *averageFPSColor = [UIColor blackColor];
    
    if (averageFPS > 45) {
        averageFPSColor = [UIColor colorWithHue:(114 / 359.0) saturation:0.99 brightness:0.89 alpha:1]; // Green
    } else if (averageFPS <= 45 && averageFPS > 30) {
        averageFPSColor = [UIColor colorWithHue:(38 / 359.0) saturation:0.99 brightness:0.89 alpha:1];  // Orange
    } else if (averageFPS < 30) {
        averageFPSColor = [UIColor colorWithHue:(6 / 359.0) saturation:0.99 brightness:0.89 alpha:1];   // Red
    }
    
    NSMutableAttributedString *mutableAttributedString = [[[NSMutableAttributedString alloc] initWithString:displayString] autorelease];
    [mutableAttributedString addAttribute:NSForegroundColorAttributeName value:averageFPSColor range:NSMakeRange(0, averageFPSStringLength)];
    
    [_averageFPSLabel setAttributedText:mutableAttributedString];
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_hideAverageFPSLabel) object:nil];
    [self performSelector:@selector(_hideAverageFPSLabel) withObject:nil afterDelay:1.5];
}

- (void)_hideAverageFPSLabel {
    CATransition *fadeTransition = [CATransition animation];
    
    [_averageFPSLabel setAttributedText:nil];
    [[_averageFPSLabel layer] addAnimation:fadeTransition forKey:kCATransition];
}

#pragma mark - Protocol Implementations

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger numberOfRows = ceilf((CGFloat)[_photos count] / (CGFloat)[FICDPhotosTableViewCell photosPerRow]);
    
    return numberOfRows;
}

- (UITableViewCell*)tableView:(UITableView*)table cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    NSString *reuseIdentifier = [FICDPhotosTableViewCell reuseIdentifier];
    
    FICDPhotosTableViewCell *tableViewCell = (FICDPhotosTableViewCell *)[table dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (tableViewCell == nil) {
        tableViewCell = [[[FICDPhotosTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier] autorelease];
        [tableViewCell setBackgroundColor:[table backgroundColor]];
        [tableViewCell setSelectionStyle:UITableViewCellSelectionStyleNone];
    }
    
    [tableViewCell setDelegate:self];
    
    NSInteger photosPerRow = [FICDPhotosTableViewCell photosPerRow];
    NSInteger startIndex = [indexPath row] * photosPerRow;
    NSInteger count = MIN(photosPerRow, [_photos count] - startIndex);
    NSArray *photos = [_photos subarrayWithRange:NSMakeRange(startIndex, count)];
    
    [tableViewCell setUsesImageTable:_usesImageTable];
    [tableViewCell setPhotos:photos];
    
    return tableViewCell;
}

#pragma mark - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat rowHeight = [FICDPhotosTableViewCell rowHeightForInterfaceOrientation:[self interfaceOrientation]];
    
    return rowHeight;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)willDecelerate {
    if (willDecelerate == NO) {
        [_tableView resetScrollingPerformanceCounters];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [_tableView resetScrollingPerformanceCounters];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    [_tableView resetScrollingPerformanceCounters];

    if (_reloadTableViewAfterScrollingAnimationEnds) {
        _reloadTableViewAfterScrollingAnimationEnds = NO;
        
        // Add a slight delay before reloading the data
        double delayInSeconds = 0.1;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self reloadTableViewAndScrollToTop:NO];
        });
    }
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (alertView == _noImagesAlertView) {
        [NSThread exit];
    }
}

#pragma mark - FICDPhotosTableViewCellDelegate

- (void)photosTableViewCell:(FICDPhotosTableViewCell *)photosTableViewCell didSelectPhoto:(FICDPhoto *)photo withImageView:(UIImageView *)imageView {
    [[FICDFullscreenPhotoDisplayController sharedDisplayController] showFullscreenPhoto:photo withThumbnailImageView:imageView];
}

#pragma mark - FICDFullscreenPhotoDisplayControllerDelegate

- (void)photoDisplayController:(FICDFullscreenPhotoDisplayController *)photoDisplayController willShowSourceImage:(UIImage *)sourceImage forPhoto:(FICDPhoto *)photo withThumbnailImageView:(UIImageView *)thumbnailImageView {
    // If we're running on iOS 7, we'll try to intelligently determine whether the photo contents underneath the status bar is light or dark.
    if ([self respondsToSelector:@selector(preferredStatusBarStyle)]) {
        if (_usesImageTable) {
            [[FICImageCache sharedImageCache] retrieveImageForEntity:photo withFormatName:FICDPhotoPixelImageFormatName completionBlock:^(id<FICEntity> entity, NSString *formatName, UIImage *image) {
                if (image != nil && [photoDisplayController isDisplayingPhoto]) {
                    [self _updateStatusBarStyleForColorAveragedImage:image];
                }
            }];
        } else {
            UIImage *colorAveragedImage = _FICDColorAveragedImageFromImage(sourceImage);
            [self _updateStatusBarStyleForColorAveragedImage:colorAveragedImage];
        }
    } else {
        [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackTranslucent animated:YES];
    }
}

- (void)photoDisplayController:(FICDFullscreenPhotoDisplayController *)photoDisplayController willHideSourceImage:(UIImage *)sourceImage forPhoto:(FICDPhoto *)photo withThumbnailImageView:(UIImageView *)thumbnailImageView {
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleDefault animated:YES];
}

#pragma mark - NSObject (NSKeyValueObserving)

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object == _tableView && [keyPath isEqualToString:@"averageFPS"]) {
        CGFloat averageFPS = [[change valueForKey:NSKeyValueChangeNewKey] floatValue];
        averageFPS = MIN(MAX(0, averageFPS), 60);
        [self _displayAverageFPS:averageFPS];
    }
}

@end

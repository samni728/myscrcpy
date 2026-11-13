#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
int main(void) { @autoreleasepool {
  CFArrayRef raw=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
  if(!raw) return 1;
  for (NSDictionary *w in (__bridge NSArray *)raw) {
     NSString *owner=w[(id)kCGWindowOwnerName] ?: @"";
     if([owner.lowercaseString containsString:@"scrcpy"]) {
       NSDictionary *b=w[(id)kCGWindowBounds]; printf("WINDOW owner=%s pid=%d title=%s x=%.0f y=%.0f w=%.0f h=%.0f\n",owner.UTF8String,[w[(id)kCGWindowOwnerPID] intValue],[w[(id)kCGWindowName] ?: @"" UTF8String],[b[@"X"] doubleValue],[b[@"Y"] doubleValue],[b[@"Width"] doubleValue],[b[@"Height"] doubleValue]);
     }
  }
  CFRelease(raw);
} return 0; }

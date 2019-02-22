//
//  StreamView.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamView.h"
#include <Limelight.h>
#import "OnScreenControls.h"
#import "DataManager.h"
#import "ControllerSupport.h"
#import "KeyboardSupport.h"

@interface StreamView ()
@property (nonatomic, strong) NSDictionary *mappings;
@end

@implementation StreamView {
    CGPoint touchLocation, originalLocation;
    BOOL touchMoved;
    OnScreenControls* onScreenControls;
    
    BOOL isInputingText;
    BOOL isDragging;
    NSTimer* dragTimer;
    
    float xDeltaFactor;
    float yDeltaFactor;
    float screenFactor;
    
    NSDictionary<NSString *, NSNumber *> *dictCodes;
}

- (void)didMoveToWindow {
    [self initializeKeyMappings];
}

- (void) setMouseDeltaFactors:(float)x y:(float)y {
    xDeltaFactor = x;
    yDeltaFactor = y;
    
    screenFactor = [[UIScreen mainScreen] scale];
}

- (void) setupOnScreenControls:(ControllerSupport*)controllerSupport swipeDelegate:(id<EdgeDetectionDelegate>)swipeDelegate {
    onScreenControls = [[OnScreenControls alloc] initWithView:self controllerSup:controllerSupport swipeDelegate:swipeDelegate];
    DataManager* dataMan = [[DataManager alloc] init];
    OnScreenControlsLevel level = (OnScreenControlsLevel)[[dataMan getSettings].onscreenControls integerValue];
    
    if (level == OnScreenControlsLevelAuto) {
        [controllerSupport initAutoOnScreenControlMode:onScreenControls];
    }
    else {
        Log(LOG_I, @"Setting manual on-screen controls level: %d", (int)level);
        [onScreenControls setLevel:level];
    }
    [self becomeFirstResponder];
}

- (Boolean)isConfirmedMove:(CGPoint)currentPoint from:(CGPoint)originalPoint {
    // Movements of greater than 10 pixels are considered confirmed
    return hypotf(originalPoint.x - currentPoint.x, originalPoint.y - currentPoint.y) >= 10;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    Log(LOG_D, @"Touch down");
    if (![onScreenControls handleTouchDownEvent:touches]) {
        UITouch *touch = [[event allTouches] anyObject];
        originalLocation = touchLocation = [touch locationInView:self];
        touchMoved = false;
        if ([[event allTouches] count] == 1 && !isDragging) {
            dragTimer = [NSTimer scheduledTimerWithTimeInterval:0.650
                                                     target:self
                                                   selector:@selector(onDragStart:)
                                                   userInfo:nil
                                                    repeats:NO];
        }
    }
}

- (void)onDragStart:(NSTimer*)timer {
    if (!touchMoved && !isDragging){
        isDragging = true;
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (![onScreenControls handleTouchMovedEvent:touches]) {
        if ([[event allTouches] count] == 1) {
            UITouch *touch = [[event allTouches] anyObject];
            CGPoint currentLocation = [touch locationInView:self];
            
            if (touchLocation.x != currentLocation.x ||
                touchLocation.y != currentLocation.y)
            {
                int deltaX = currentLocation.x - touchLocation.x;
                int deltaY = currentLocation.y - touchLocation.y;
                
                deltaX *= xDeltaFactor * screenFactor;
                deltaY *= yDeltaFactor * screenFactor;
                
                if (deltaX != 0 || deltaY != 0) {
                    LiSendMouseMoveEvent(deltaX, deltaY);
                    touchLocation = currentLocation;
                    
                    // If we've moved far enough to confirm this wasn't just human/machine error,
                    // mark it as such.
                    if ([self isConfirmedMove:touchLocation from:originalLocation]) {
                        touchMoved = true;
                    }
                }
            }
        } else if ([[event allTouches] count] == 2) {
            CGPoint firstLocation = [[[[event allTouches] allObjects] objectAtIndex:0] locationInView:self];
            CGPoint secondLocation = [[[[event allTouches] allObjects] objectAtIndex:1] locationInView:self];
            
            CGPoint avgLocation = CGPointMake((firstLocation.x + secondLocation.x) / 2, (firstLocation.y + secondLocation.y) / 2);
            if (touchLocation.y != avgLocation.y) {
                LiSendScrollEvent(avgLocation.y - touchLocation.y);
            }

            // If we've moved far enough to confirm this wasn't just human/machine error,
            // mark it as such.
            if ([self isConfirmedMove:firstLocation from:originalLocation]) {
                touchMoved = true;
            }
            
            touchLocation = avgLocation;
        }
    }
    
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    Log(LOG_D, @"Touch up");
    if (![onScreenControls handleTouchUpEvent:touches]) {
        [dragTimer invalidate];
        dragTimer = nil;
        if (isDragging) {
            isDragging = false;
            LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
        } else if (!touchMoved) {
            if ([[event allTouches] count] == 3) {
                if (isInputingText) {
                    Log(LOG_D, @"Closing the keyboard");
                    [_keyInputField resignFirstResponder];
                    isInputingText = false;
                } else {
                    Log(LOG_D, @"Opening the keyboard");
                    // Prepare the textbox used to capture keyboard events.
                    _keyInputField.delegate = self;
                    _keyInputField.text = @"0";
                    [_keyInputField becomeFirstResponder];
                    [_keyInputField addTarget:self action:@selector(onKeyboardPressed:) forControlEvents:UIControlEventEditingChanged];
                    
                    // Undo causes issues for our state management, so turn it off
                    [_keyInputField.undoManager disableUndoRegistration];
                    
                    isInputingText = true;
                }
            } else if ([[event allTouches] count]  == 2) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    Log(LOG_D, @"Sending right mouse button press");
                    
                    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
                    
                    // Wait 100 ms to simulate a real button press
                    usleep(100 * 1000);
                    
                    LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
                });
            } else if ([[event allTouches] count]  == 1) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    if (!self->isDragging){
                        Log(LOG_D, @"Sending left mouse button press");
                        
                        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
                        
                        // Wait 100 ms to simulate a real button press
                        usleep(100 * 1000);
                    }
                    self->isDragging = false;
                    LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
                });
            }
        }
        
        // We we're moving from 2+ touches to 1. Synchronize the current position
        // of the active finger so we don't jump unexpectedly on the next touchesMoved
        // callback when finger 1 switches on us.
        if ([[event allTouches] count] - [touches count] == 1) {
            NSMutableSet *activeSet = [[NSMutableSet alloc] initWithCapacity:[[event allTouches] count]];
            [activeSet unionSet:[event allTouches]];
            [activeSet minusSet:touches];
            touchLocation = [[activeSet anyObject] locationInView:self];
            
            // Mark this touch as moved so we don't send a left mouse click if the user
            // right clicks without moving their other finger.
            touchMoved = true;
        }
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
//    // This method is called when the "Return" key is pressed.
//    LiSendKeyboardEvent(0x0d, KEY_ACTION_DOWN, 0);
//    usleep(50 * 1000);
//    LiSendKeyboardEvent(0x0d, KEY_ACTION_UP, 0);
    return NO;
}

- (void)onKeyboardPressed:(UITextField *)textField {
//    NSString* inputText = textField.text;
//    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
//        // If the text became empty, we know the user pressed the backspace key.
//        if ([inputText isEqual:@""]) {
//            LiSendKeyboardEvent(0x08, KEY_ACTION_DOWN, 0);
//            usleep(50 * 1000);
//            LiSendKeyboardEvent(0x08, KEY_ACTION_UP, 0);
//        } else {
//            // Character 0 will be our known sentinel value
//            for (int i = 1; i < [inputText length]; i++) {
//                struct KeyEvent event = [KeyboardSupport translateKeyEvent:[inputText characterAtIndex:i] withModifierFlags:0];
//                if (event.keycode == 0) {
//                    // If we don't know the code, don't send anything.
//                    Log(LOG_W, @"Unknown key code: [%c]", [inputText characterAtIndex:i]);
//                    continue;
//                }
//                [self sendLowLevelEvent:event];
//            }
//        }
//    });
//
//    // Reset text field back to known state
//    textField.text = @"0";
//
//    // Move the insertion point back to the end of the text box
//    UITextRange *textRange = [textField textRangeFromPosition:textField.endOfDocument toPosition:textField.endOfDocument];
//    [textField setSelectedTextRange:textRange];
}

- (void)specialCharPressed:(UIKeyCommand *)cmd {
    struct KeyEvent event = [KeyboardSupport translateKeyEvent:0x20 withModifierFlags:[cmd modifierFlags]];
    event.keycode = [[dictCodes valueForKey:[cmd input]] intValue];
    [self sendLowLevelEvent:event];
}

- (void)keyPressed:(UIKeyCommand *)cmd {
    struct KeyEvent event = [KeyboardSupport translateKeyEvent:[[cmd input] characterAtIndex:0] withModifierFlags:[cmd modifierFlags]];
    [self sendLowLevelEvent:event];
}

- (void)sendLowLevelEvent:(struct KeyEvent)event {
//    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
//        // When we want to send a modified key (like uppercase letters) we need to send the
//        // modifier ("shift") seperately from the key itself.
//        if (event.modifier != 0) {
//            LiSendKeyboardEvent(event.modifierKeycode, KEY_ACTION_DOWN, event.modifier);
//        }
//        LiSendKeyboardEvent(event.keycode, KEY_ACTION_DOWN, event.modifier);
//        usleep(50 * 1000);
//        LiSendKeyboardEvent(event.keycode, KEY_ACTION_UP, event.modifier);
//        if (event.modifier != 0) {
//            LiSendKeyboardEvent(event.modifierKeycode, KEY_ACTION_UP, event.modifier);
//        }
//    });
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (NSArray<UIKeyCommand *> *)keyCommands
{
    NSString *charset = @"qwertyuiopasdfghjklzxcvbnm1234567890\t§[]\\'\"/.,`<>-´ç+`¡'º;ñ= ";
    
    NSMutableArray<UIKeyCommand *> * commands = [NSMutableArray<UIKeyCommand *> array];
    dictCodes = [[NSDictionary alloc] initWithObjectsAndKeys: [NSNumber numberWithInt: 0x0d], @"\r", [NSNumber numberWithInt: 0x08], @"\b", [NSNumber numberWithInt: 0x1b], UIKeyInputEscape, [NSNumber numberWithInt: 0x28], UIKeyInputDownArrow, [NSNumber numberWithInt: 0x26], UIKeyInputUpArrow, [NSNumber numberWithInt: 0x25], UIKeyInputLeftArrow, [NSNumber numberWithInt: 0x27], UIKeyInputRightArrow, nil];
    
    [charset enumerateSubstringsInRange:NSMakeRange(0, charset.length)
                                options:NSStringEnumerationByComposedCharacterSequences
                             usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:0 action:@selector(keyPressed:)]];
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierShift action:@selector(keyPressed:)]];
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierControl action:@selector(keyPressed:)]];
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierAlternate action:@selector(keyPressed:)]];
                             }];
    
    for (NSString *c in [dictCodes keyEnumerator]) {
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:0
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierShift
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierShift | UIKeyModifierAlternate
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierShift | UIKeyModifierControl
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierControl
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierControl | UIKeyModifierAlternate
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierAlternate
                                                       action:@selector(specialCharPressed:)]];
    }
    
    return commands;
}


#pragma mark - UIKeyCommand

- (UIKeyCommand *)_keyCommandForEvent:(UIEvent *)event { // UIPhysicalKeyboardEvent
    NSLog(@"keyCommandForEvent: %@\n\
          type = %li\n\
          keycode = %@\n\
          keydown = %@\n\
          key = %@\n\
          modifierFlags = %@\n\n",
          event.debugDescription,
          (long)event.type,
          [event valueForKey:@"_keyCode"],
          [event valueForKey:@"_isKeyDown"],
          [event valueForKey:@"_unmodifiedInput"],
          [event valueForKey:@"_modifierFlags"]);

    unsigned short keyCode = [self translateKeyCode:[[event valueForKey:@"_keyCode"] unsignedShortValue]];
    BOOL isKeyDown = [[event valueForKey:@"_isKeyDown"] boolValue];
    NSUInteger modifierFlags = [self translateKeyModifierFlags:[[event valueForKey:@"_modifierFlags"] unsignedIntegerValue]];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        if (keyCode == 0xC0 && (modifierFlags & MODIFIER_CTRL)) { // Tilde/Grave
            if (isKeyDown) {
                LiSendKeyboardEvent(0xA2, KEY_ACTION_UP, 0); // Control up
                usleep(50 * 1000);
                LiSendKeyboardEvent(0x1B, KEY_ACTION_DOWN, 0); // ESC down
            } else {
                LiSendKeyboardEvent(0x1B, KEY_ACTION_UP, 0); // ESC up
            }
            
            return;
        }
        
        LiSendKeyboardEvent(keyCode, isKeyDown ? KEY_ACTION_DOWN : KEY_ACTION_UP, modifierFlags);
    });

    return nil;
}

// Copied from Carbon framework on macOS
typedef NS_OPTIONS(NSUInteger, NSEventModifierFlags) {
    NSEventModifierFlagCapsLock           = 1 << 16, // Set if Caps Lock key is pressed.
    NSEventModifierFlagShift              = 1 << 17, // Set if Shift key is pressed.
    NSEventModifierFlagControl            = 1 << 18, // Set if Control key is pressed.
    NSEventModifierFlagOption             = 1 << 19, // Set if Option or Alternate key is pressed.
    NSEventModifierFlagCommand            = 1 << 20, // Set if Command key is pressed.
    NSEventModifierFlagNumericPad         = 1 << 21, // Set if any key in the numeric keypad is pressed.
    NSEventModifierFlagHelp               = 1 << 22, // Set if the Help key is pressed.
    NSEventModifierFlagFunction           = 1 << 23, // Set if any function key is pressed.
    
    // Used to retrieve only the device-independent modifier flags, allowing applications to mask off the device-dependent modifier flags, including event coalescing information.
    NSEventModifierFlagDeviceIndependentFlagsMask    = 0xffff0000UL
};

struct KeyMapping {
    unsigned short iOS;
    short windows;
};

static struct KeyMapping keys[] = {
    {4, 'A'},
    {5, 'B'},
    {6, 'C'},
    {7, 'D'},
    {8, 'E'},
    {9, 'F'},
    {10, 'G'},
    {11, 'H'},
    {12, 'I'},
    {13, 'J'},
    {14, 'K'},
    {15, 'L'},
    {16, 'M'},
    {17, 'N'},
    {18, 'O'},
    {19, 'P'},
    {20, 'Q'},
    {21, 'R'},
    {22, 'S'},
    {23, 'T'},
    {24, 'U'},
    {25, 'V'},
    {26, 'W'},
    {27, 'X'},
    {28, 'Y'},
    {29, 'Z'},
    
    {39, '0'},
    {30, '1'},
    {31, '2'},
    {32, '3'},
    {33, '4'},
    {34, '5'},
    {35, '6'},
    {36, '7'},
    {37, '8'},
    {38, '9'},
    
    {46, 0xBB}, // Equals
    {45, 0xBD}, // Minus
    {48, 0xDD}, // RightBracket
    {47, 0xDB}, // LeftBracket
    {52, 0xDE}, // Quote
    {51, 0xBA}, // Semicolon
    {49, 0xDC}, // Backslash
    {54, 0xBC}, // Comma
    {56, 0xBF}, // Slash
    {55, 0xBE}, // Period
    {53, 0xC0}, // Grave
    
    // Keypad
    {99, 0x6E}, // Decimal
    {85, 0x6A}, // Multiply
    {87, 0x6B}, // Plus
    {83, 0xFE}, // Clear
    {84, 0x6F}, // Divide
    {88, 0x0D}, // Enter
    {86, 0x6D}, // Minus
    {103, 0xBB}, // Equals
    {98, 0x60}, // 0
    {89, 0x61}, // 1
    {90, 0x62}, // 2
    {91, 0x63}, // 3
    {92, 0x64}, // 4
    {93, 0x65}, // 5
    {94, 0x66}, // 6
    {95, 0x67}, // 7
    {96, 0x68}, // 8
    {97, 0x69}, // 9
    
    {42, 0x08}, // Delete
    {43, 0x09}, // Tab
    {40, 0x0D}, // Return
    {225, 0xA0}, // Shift
    {224, 0xA2}, // Control
    {226, 0xA4}, // Option
    {57, 0x14}, // CapsLock
    {41, 0x1B}, // Escape
    {44, 0x20}, // Space
    {75, 0x21}, // PageUp
    {78, 0x22}, // PageDown
    {77, 0x23}, // End
    {74, 0x24}, // Home
    {80, 0x25}, // LeftArrow
    {82, 0x26}, // UpArrow
    {79, 0x27}, // RightArrow
    {81, 0x28}, // DownArrow
    {76, 0x2E}, // ForwardDelete
//    {kVK_Help, 0x2F}, // Help
    {227, 0x5B}, // Command
    {231, 0x5C}, // RightCommand
    {229, 0xA1}, // RightShift
    {230, 0xA5}, // RightOption
    {228, 0xA3}, // RightControl
//    {kVK_Mute, 0xAD}, // Mute
//    {kVK_VolumeDown, 0xAE}, // VolumeDown
//    {kVK_VolumeUp, 0xAF}, // VolumeUp
    
    {58, 0x70}, // F1
    {59, 0x71}, // F2
    {60, 0x72}, // F3
    {61, 0x73}, // F4
    {62, 0x74}, // F5
    {63, 0x75}, // F6
    {64, 0x76}, // F7
    {65, 0x77}, // F8
    {66, 0x78}, // F9
    {67, 0x79}, // F10
    {68, 0x7A}, // F11
    {69, 0x7B}, // F12
    {104, 0x7C}, // F13
    {105, 0x7D}, // F14
    {106, 0x7E}, // F15
    {107, 0x7F}, // F16
    {108, 0x80}, // F17
    {109, 0x81}, // F18
    {110, 0x82}, // F19
    {111, 0x83}, // F20
};

- (void)initializeKeyMappings {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (size_t i = 0; i < sizeof(keys) / sizeof(struct KeyMapping); i++) {
        struct KeyMapping m = keys[i];
        [d setObject:@(m.windows) forKey:@(m.iOS)];
    }
    self.mappings = [NSDictionary dictionaryWithDictionary:d];
}

- (short)translateKeyCode:(unsigned short)keyCode {
    if (![self.mappings objectForKey:@(keyCode)]) {
        return 0;
    }
    return [self.mappings[@(keyCode)] shortValue];
}

- (char)translateKeyModifierFlags:(NSUInteger)modifierFlags {
    char modifiers = 0;
    if (modifierFlags & NSEventModifierFlagShift) {
        modifiers |= MODIFIER_SHIFT;
    }
    if (modifierFlags & NSEventModifierFlagControl) {
        modifiers |= MODIFIER_CTRL;
    }
    if (modifierFlags & NSEventModifierFlagOption) {
        modifiers |= MODIFIER_ALT;
    }
    return modifiers;
}


@end

/* -*- ObjC -*-

  MacOS X implementation of the SKK input method.

  Copyright (C) 2007-2013 Tomotaka SUWA <tomotaka.suwa@gmail.com>

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

*/

#include "SKKInputController.h"
#include "SKKLayoutManager.h"
#include "SKKInputSession.h"
#include "SKKBackEnd.h"

#include "SKKPreProcessor.h"
#include "SKKConstVars.h"

#include "MacInputSessionParameter.h"
#include "MacInputModeMenu.h"
#include "MacInputModeWindow.h"

@interface SKKInputController (Local)

- (void)initializeKeyboardLayout;
- (BOOL)privateMode;
- (void)setPrivateMode:(BOOL)flag;
- (BOOL)directMode;
- (void)setDirectMode:(BOOL)flag;
- (void)workAroundForJRE;
- (void)debug:(NSString*)message;
- (NSUserDefaults*)defaults;

@end

@implementation SKKInputController

- (instancetype)initWithServer:(id)server delegate:(id)delegate client:(id)client {
    self = [super initWithServer:server delegate:delegate client:client];
    if(self) {
        client_ = client;
        activated_ = NO;
        proxy_ = [[SKKServerProxy alloc] init];
        menu_ = [[SKKInputMenu alloc] initWithClient:client];

        layout_ = new SKKLayoutManager(client_);
        session_ = new SKKInputSession(new MacInputSessionParameter(client_, layout_));
        modeIcon_ = new MacInputModeWindow(layout_);

        session_->AddInputModeListener(new MacInputModeMenu(menu_));
        session_->AddInputModeListener(modeIcon_);
    }

    return self;
}

- (void)dealloc {
    delete session_;
    delete layout_;
}

// IMKServerInput
- (BOOL)handleEvent:(NSEvent*)event client:(id)sender {
    if([self directMode]) return NO;

    SKKInputMode current = [menu_ currentInputMode];

    SKKEvent param = SKKPreProcessor::theInstance().Execute(event);

    bool result = session_->HandleEvent(param);

    if(current != [menu_ currentInputMode] || param.id == SKK_JMODE) {
        [self workAroundForJRE];
    }

    return result ? YES : NO;
}

- (void)commitComposition:(id)sender {
    if([self directMode]) return;

    [self debug:@"commitComposition"];

    session_->Commit();
}

// IMKStateSetting
- (void)activateServer:(id)sender {
    [NSUserDefaults resetStandardUserDefaults];
    
    if([self directMode]) return;

    [self debug:@"activateServer"];

    [self initializeKeyboardLayout];

    activated_ = YES;

    session_->Activate();
}

- (void)deactivateServer:(id)sender {
    if([self directMode]) return;

    [self debug:@"deactivateServer"];

    session_->Deactivate();
}

- (void)setValue:(id)value forTag:(long)tag client:(id)sender {
    if([self directMode]) return;

    if(tag != kTextServiceInputModePropertyTag) return;

    [self debug:@"setValue"];

    // 「AquaSKK 統合」の場合
    if([menu_ convertIdToEventId:value] == SKK_NULL) {
        bool individual = ([[self defaults] boolForKey:SKKUserDefaultKeys::use_individual_input_mode] == YES);

        // SelectInputMode → setValue の無限ループが発生するため、
        // 最初の一回だけに限定する
        if(activated_) {
            activated_ = NO;

            if(individual) {
                NSString* identifier = [menu_ convertInputModeToId:[menu_ currentInputMode]];
                SKKEvent param;

                param.id = [menu_ convertIdToEventId:identifier];
                session_->HandleEvent(param);

                modeIcon_->SelectInputMode([menu_ currentInputMode]);
            } else {
                NSString* identifier = [menu_ convertInputModeToId:[menu_ unifiedInputMode]];
                SKKEvent param;

                param.id = [menu_ convertIdToEventId:identifier];
                session_->HandleEvent(param);
            }
        }
    } else {
        // 個々の入力モードを選択している場合

      if (activated_) {
        activated_ = NO;

        SKKEvent param;

        // ex) "com.apple.inputmethod.Roman" => SKK_ASCII_MODE
        param.id = [menu_ convertIdToEventId:(NSString*)value];

        if(param.id != InvalidInputMode) {
            session_->HandleEvent(param);

            modeIcon_->SelectInputMode([menu_ convertIdToInputMode:(NSString*)value]);
        }
      }
    }
}

// IMKInputController
- (NSMenu*)menu {
    struct {
        const char* title;
        SEL handler;
        SEL state;
    } items[] = {
        { "環境設定",                 @selector(showPreferences:),   0 },
        { "直接入力モード",           @selector(toggleDirectMode:),  @selector(directMode) },
        { "プライベートモード",       @selector(togglePrivateMode:), @selector(privateMode) },
        { "設定ファイルの再読み込み", @selector(reloadComponents:),  0 },
#ifdef SKK_DEBUG
        { "デバッグ情報",             @selector(showDebugInfo:),     0 },
#endif
        { "separator",                0,                             0 },
        { "Web::日本語を快適に",      @selector(webHome:),           0 },
        { "Web::SourceForge.JP",      @selector(webSourceForge:),    0 },
        { "Web::Wiki",                @selector(webWiki:),           0 },
        { 0,                          0,                             0 }
    };

    NSMenu* inputMenu = [[NSMenu alloc] initWithTitle:@"AquaSKK"];

    for(int i = 0; items[i].title != 0; ++ i) {
        NSString* title = @(items[i].title);
        SEL handler = items[i].handler;
        NSMenuItem* item;

        if(handler != 0) {
            item = [[NSMenuItem alloc] initWithTitle:title
                                              action:handler
                                       keyEquivalent:@""];
        } else {
            item = [NSMenuItem separatorItem];
        }
        
        if(items[i].state != 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [item setState:(NSInteger)[self performSelector:items[i].state]];
#pragma clang pop

            if(items[i].state == @selector(directMode)) {
                NSWorkspace* workspace = [NSWorkspace sharedWorkspace];
                NSString* path = [workspace absolutePathForAppBundleWithIdentifier:[client_ bundleIdentifier]];
                NSString* name = [[NSFileManager defaultManager] displayNameAtPath:path];
                [item setTitle:[NSString stringWithFormat:@"“%@” では直接入力", name]];
            }
        }

        [inputMenu addItem:item];
    }

    return inputMenu;
}

// handling menu items
- (void)showPreferences:(id)sender {
    NSString* path = [NSString stringWithFormat:@"%@/AquaSKKPreferences.app",
                               [[NSBundle mainBundle] sharedSupportPath]];

    [[NSWorkspace sharedWorkspace] launchApplication:path];
}

- (void)togglePrivateMode:(id)sender {
    [self setPrivateMode:![self privateMode]];

    SKKBackEnd::theInstance().EnablePrivateMode([self privateMode]);
}

- (void)toggleDirectMode:(id)sender {
    [self setDirectMode:![self directMode]];
}

- (void)reloadComponents:(id)sender {
    [proxy_ reloadComponents];
}

- (void)showDebugInfo:(id)sender {
    NSMutableString* info = [[NSMutableString alloc] initWithCapacity:0];
    NSRect rect;

    [info appendFormat:@"bundleId = %@\n", [client_ bundleIdentifier]];
    [info appendFormat:@"attributes = %@\n",
          [client_ attributesForCharacterIndex:0 lineHeightRectangle:&rect]];
    [info appendFormat:@"inline rect = %@\n", NSStringFromRect(rect)];
    [info appendFormat:@"selected range = %@\n",NSStringFromRange([client_ selectedRange])];
    [info appendFormat:@"marked range = %@\n", NSStringFromRange([client_ markedRange])];
    [info appendFormat:@"supports unicode = %@\n",
          ([client_ supportsUnicode] == 1 ? @"YES" : @"NO")];
    [info appendFormat:@"window level = %d\n", [client_ windowLevel]];
    [info appendFormat:@"length = %ld\n", [client_ length]];
    [info appendFormat:@"valid attributes = %@\n", [client_ validAttributesForMarkedText]];

    NSAlert* alert = [[NSAlert alloc] init];
    [alert addButtonWithTitle:@"OK"];
    [alert setMessageText:@"デバッグ情報"];
    [alert setInformativeText:info];
    [alert setAlertStyle:NSInformationalAlertStyle];
    [alert setIcon:[NSImage imageNamed:NSImageNameInfo]];
    [[alert window] setLevel:kCGPopUpMenuWindowLevel];
    [[alert window] setTitle:@"AquaSKK"];

    [alert beginSheetModalForWindow:0 modalDelegate:self didEndSelector:0 contextInfo:0];

    NSPasteboard* pb = [NSPasteboard generalPasteboard];

    [pb declareTypes:@[NSStringPboardType] owner:self];
    [pb setString:info forType:NSStringPboardType];
}

- (void)openURL:(NSString*)url {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

- (void)webHome:(id)sender {
    [self openURL:@"http://aquaskk.sourceforge.jp/"];
}

- (void)webSourceForge:(id)sender {
    [self openURL:@"http://sourceforge.jp/projects/aquaskk/"];
}

- (void)webWiki:(id)sender {
    [self openURL:@"http://sourceforge.jp/projects/aquaskk/wiki/FrontPage"];
}

@end

@implementation SKKInputController (Local)

- (void)initializeKeyboardLayout {
    NSString* keyboardLayout = [[self defaults] stringForKey:SKKUserDefaultKeys::keyboard_layout];
    [client_ overrideKeyboardWithKeyboardNamed:keyboardLayout];
}

- (BOOL)privateMode {
    return [[self defaults] boolForKey:SKKUserDefaultKeys::enable_private_mode];
}

- (void)setPrivateMode:(BOOL)flag {
    [[self defaults] setBool:flag forKey:SKKUserDefaultKeys::enable_private_mode];
}

- (BOOL)directMode {
    NSArray* clients = [[self defaults] arrayForKey:SKKUserDefaultKeys::direct_clients];

    return [clients containsObject:[client_ bundleIdentifier]] == YES;
}

- (void)setDirectMode:(BOOL)flag {
    NSArray* current = [[self defaults] arrayForKey:SKKUserDefaultKeys::direct_clients];
    NSMutableArray* result = [NSMutableArray arrayWithArray:current];
    NSString* client = [client_ bundleIdentifier];

    if(flag) {
        [result addObject:client];
    } else {
        [result removeObject:client];
    }

    [[self defaults] setObject:result forKey:SKKUserDefaultKeys::direct_clients];
}

- (void)workAroundForJRE {
    NSWorkspace* workspace = [NSWorkspace sharedWorkspace];
    NSString* path = [workspace absolutePathForAppBundleWithIdentifier:[client_ bundleIdentifier]];
    NSBundle* bundle = [NSBundle bundleWithPath:path];

    if(bundle) {
        // Info.plist に Java キーが含まれていなければ無視
        if([bundle objectForInfoDictionaryKey:@"Java"] == nil &&
           [bundle objectForInfoDictionaryKey:@"Eclipse"] == nil) {
            [self debug:@"Not Java Application"];
            return;
        }
    } else {
        // 直接 Java を起動していない場合は無視
        if(![[client_ bundleIdentifier] hasPrefix:@"com.apple.javajdk"]) {
            [self debug:@"Not JDK"];
            return;
        }
    }

    [self debug:@"workAroundForJRE"];

    // Ctrl-L を強制挿入することで、アプリケーション側のキー処理を無効化する
    NSString* null = [NSString stringWithFormat:@"%c", 0x0c];
    NSRange range = NSMakeRange(NSNotFound, NSNotFound);

    [client_ setMarkedText:null selectionRange:range replacementRange:range];
    [client_ setMarkedText:@"" selectionRange:range replacementRange:range];
}

- (void)debug:(NSString*)str {
#ifdef SKK_DEBUG
    NSLog(@"%@: %@", [client_ bundleIdentifier], str);
#endif
}

- (NSUserDefaults*)defaults {
    return [NSUserDefaults standardUserDefaults];
}

@end

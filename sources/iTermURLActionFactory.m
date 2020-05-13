//
//  iTermURLActionFactory.m
//  iTerm2
//
//  Created by George Nachman on 2/26/17.
//
//

#import "iTermURLActionFactory.h"

#import "ContextMenuActionPrefsController.h"
#import "DebugLogging.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermPathFinder.h"
#import "iTermSemanticHistoryController.h"
#import "iTermTextExtractor.h"
#import "iTermURLStore.h"
#import "NSCharacterSet+iTerm.h"
#import "NSStringITerm.h"
#import "NSURL+iTerm.h"
#import "RegexKitLite.h"
#import "SCPPath.h"
#import "SmartSelectionController.h"
#import "URLAction.h"
#import "VT100RemoteHost.h"

static NSString *const iTermURLActionFactoryCancelPathfinders = @"iTermURLActionFactoryCancelPathfinders";

typedef enum {
    iTermURLActionFactoryPhaseHypertextLink,
    iTermURLActionFactoryPhaseExistingFile,
    iTermURLActionFactoryPhaseExistingFileRespectingHardNewlines,
    iTermURLActionFactoryPhaseSmartSelectionAction,
    iTermURLActionFactoryPhaseAnyStringSemanticHistory,
    iTermURLActionFactoryPhaseURLLike,
    iTermURLActionFactoryPhaseSecureCopy,
    iTermURLActionFactoryPhaseFailed
} iTermURLActionFactoryPhase;

@interface iTermURLActionFactory()
@property (nonatomic) VT100GridCoord coord;
@property (nonatomic) BOOL respectHardNewlines;
@property (nonatomic, copy) NSString *workingDirectory;
@property (nonatomic, strong) VT100RemoteHost *remoteHost;
@property (nonatomic, copy) NSDictionary<NSNumber *, NSString *> *selectors;
@property (nonatomic, copy) NSArray *rules;
@property (nonatomic, strong) iTermTextExtractor *extractor;
@property (nonatomic, strong) iTermSemanticHistoryController *semanticHistoryController;
@property (nonatomic, copy) SCPPath *(^pathFactory)(NSString *, int);
@property (nonatomic, copy) void (^completion)(URLAction *);
@property (nonatomic) iTermURLActionFactoryPhase phase;
@property (nonatomic) BOOL workingDirectoryIsLocal;

@property (nonatomic, strong) NSMutableIndexSet *continuationCharsCoords;
@property (nonatomic, strong) NSMutableArray *prefixCoords;
@property (nonatomic, strong) NSString *prefix;
@property (nonatomic, strong) NSMutableArray *suffixCoords;
@property (nonatomic, strong) NSString *suffix;
@end

static NSMutableArray<iTermURLActionFactory *> *sFactories;

@implementation iTermURLActionFactory {
    BOOL _finished;
    iTermPathFinder *_pathfinder;
}

+ (void)urlActionAtCoord:(VT100GridCoord)coord
     respectHardNewlines:(BOOL)respectHardNewlines
        workingDirectory:(NSString *)workingDirectory
              remoteHost:(VT100RemoteHost *)remoteHost
               selectors:(NSDictionary<NSNumber *, NSString *> *)selectors
                   rules:(NSArray *)rules
               extractor:(iTermTextExtractor *)extractor
semanticHistoryController:(iTermSemanticHistoryController *)semanticHistoryController
             pathFactory:(SCPPath *(^)(NSString *, int))pathFactory
              completion:(void (^)(URLAction *))completion {
    iTermURLActionFactory *factory = [[iTermURLActionFactory alloc] init];
    factory.coord = coord;
    factory.respectHardNewlines = respectHardNewlines;
    factory.workingDirectory = workingDirectory;
    factory.remoteHost = remoteHost;
    factory.selectors = selectors;
    factory.rules = rules;
    factory.extractor = extractor;
    factory.semanticHistoryController = semanticHistoryController;
    factory.pathFactory = pathFactory;
    factory.completion = completion;
    factory.phase = iTermURLActionFactoryPhaseHypertextLink;
    [[NSNotificationCenter defaultCenter] addObserver:factory
                                             selector:@selector(cancelPathfinders:)
                                                 name:iTermURLActionFactoryCancelPathfinders
                                               object:nil];

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sFactories = [NSMutableArray array];
    });

    [sFactories addObject:factory];
    [factory tryCurrentPhase];
}

- (iTermTextExtractor *)extractor {
    VT100GridRange logicalWindow = _extractor.logicalWindow;
    const int width = [_extractor.dataSource width];
    if (logicalWindow.location >= width) {
        logicalWindow.location = MAX(0, width - 1);
    }
    if (logicalWindow.location + logicalWindow.length > width) {
        logicalWindow.length = width - logicalWindow.location;
    }
    _extractor.logicalWindow = logicalWindow;
    return _extractor;
}

// This is always eventually callsed.
- (void)completeWithAction:(URLAction *)action {
    DLog(@"Phase completed successfully with action %@", action);
    _finished = YES;
    self.completion(action);
    [sFactories removeObject:self];
}

- (void)fail {
    DLog(@"Phase failed");
    self.phase = self.phase + 1;
    [self tryCurrentPhase];
}

- (void)tryCurrentPhase {
    if (self.extractor.dataSource == nil) {
        [self completeWithAction:nil];
        return;
    }
    DLog(@"Try phase %@", @(self.phase));
    switch (self.phase) {
        case iTermURLActionFactoryPhaseHypertextLink:
            [self tryHypertextLink];
            break;
        case iTermURLActionFactoryPhaseExistingFile:
            [self tryExistingFileForceRespectingHardNewlines:NO];
            break;
        case iTermURLActionFactoryPhaseExistingFileRespectingHardNewlines:
            [self tryExistingFileForceRespectingHardNewlines:YES];
            break;
        case iTermURLActionFactoryPhaseSmartSelectionAction:
            [self trySmartSelectionAction];
            break;
        case iTermURLActionFactoryPhaseAnyStringSemanticHistory:
            [self tryAnyStringSemanticHistory];
            break;
        case iTermURLActionFactoryPhaseURLLike:
            [self tryURLLike];
            break;
        case iTermURLActionFactoryPhaseSecureCopy:
            [self trySecureCopy];
            break;
        case iTermURLActionFactoryPhaseFailed:
            [self completeWithAction:nil];
            break;
    }
}

- (void)tryHypertextLink {
    URLAction *action;
    action = [self urlActionForHypertextLink];
    if (action) {
        [self completeWithAction:action];
    } else {
        [self fail];
    }
}

- (void)tryExistingFileForceRespectingHardNewlines:(BOOL)forceRespect {
    if (forceRespect && self.respectHardNewlines) {
        // No need to force it
        [self fail];
        return;
    }
    NSString *savedPrefix = self.prefix;
    NSString *savedSuffix = self.suffix;
    NSMutableIndexSet *savedContinuationCharsCoords = [self.continuationCharsCoords mutableCopy];
    NSMutableArray *savedPrefixCoords = [self.prefixCoords mutableCopy];
    NSMutableArray *savedSuffixCoords = [self.suffixCoords mutableCopy];

    self.continuationCharsCoords = [NSMutableIndexSet indexSet];
    self.prefixCoords = [NSMutableArray array];
    self.prefix = [self.extractor wrappedStringAt:self.coord
                                          forward:NO
                              respectHardNewlines:forceRespect || self.respectHardNewlines
                                         maxChars:[iTermAdvancedSettingsModel maxSemanticHistoryPrefixOrSuffix]
                                continuationChars:self.continuationCharsCoords
                              convertNullsToSpace:NO
                                           coords:self.prefixCoords];
    DLog(@"Prefix respectingHardNewlines=%@ from %@ is %@ with coords %@",
         @(forceRespect || self.respectHardNewlines),
         VT100GridCoordDescription(self.coord), self.prefix, self.prefixCoords);

    self.suffixCoords = [NSMutableArray array];
    self.suffix = [self.extractor wrappedStringAt:self.coord
                                          forward:YES
                              respectHardNewlines:forceRespect || self.respectHardNewlines
                                         maxChars:[iTermAdvancedSettingsModel maxSemanticHistoryPrefixOrSuffix]
                                continuationChars:self.continuationCharsCoords
                              convertNullsToSpace:NO
                                           coords:self.suffixCoords];
    DLog(@"Suffix respectingHardNewlines=%@ from %@ is %@ with coords %@",
         @(forceRespect || self.respectHardNewlines),
         VT100GridCoordDescription(self.coord), self.suffix, self.suffixCoords);

    [self urlActionForExistingFileWithCompletion:^(URLAction *action, BOOL workingDirectoryIsLocal) {
        self.workingDirectoryIsLocal = workingDirectoryIsLocal;
        if (action) {
            [self completeWithAction:action];
        } else {
            if (forceRespect) {
                self.prefix = savedPrefix;
                self.suffix = savedSuffix;
                self.continuationCharsCoords = savedContinuationCharsCoords;
                self.prefixCoords = savedPrefixCoords;
                self.suffixCoords = savedSuffixCoords;
                DLog(@"Restore coords. set prefixCoords=%@\nset suffixCoords=%@",
                     self.prefixCoords, self.suffixCoords);
            }
            [self fail];
        }
    }];
}

- (void)trySmartSelectionAction {
    URLAction *action = [self urlActionForSmartSelection];
    if (action) {
        [self completeWithAction:action];
    } else {
        [self fail];
    }
}

- (void)tryAnyStringSemanticHistory {
    URLAction *action = [self urlActionForAnyStringSemanticHistory];
    if (action) {
        [self completeWithAction:action];
    } else {
        [self fail];
    }
}

- (void)tryURLLike {
    // No luck. Look for something vaguely URL-like.
    URLAction *action = [self urlActionForURLLike];
    if (action) {
        [self completeWithAction:action];
    } else {
        [self fail];
    }
}

- (void)trySecureCopy {
    // TODO: We usually don't get here because "foo.txt" looks enough like a URL that we do a DNS
    // lookup and fail. It'd be nice to fallback to an SCP file path.
    // See if we can conjure up a secure copy path.
    URLAction *action = [self urlActionWithSecureCopy];
    if (action) {
        [self completeWithAction:action];
    } else {
        [self fail];
    }
}

#pragma mark - Sub-factories

- (URLAction *)urlActionForHypertextLink {
    iTermTextExtractor *extractor = self.extractor;
    screen_char_t oc = [extractor characterAt:self.coord];
    NSString *urlId = nil;
    NSURL *url = [extractor urlOfHypertextLinkAt:self.coord urlId:&urlId];
    if (url != nil) {
        DLog(@"Found hypertext url %@", url);
        URLAction *action = [URLAction urlActionToOpenURL:url.absoluteString];
        action.hover = YES;
        action.range = [extractor rangeOfCoordinatesAround:self.coord
                                           maximumDistance:1000
                                               passingTest:^BOOL(screen_char_t *c, VT100GridCoord coord) {
                                                   if (c->urlCode == oc.urlCode) {
                                                       return YES;
                                                   }
                                                   NSString *thisId;
                                                   NSURL *thisURL = [extractor urlOfHypertextLinkAt:coord urlId:&thisId];
                                                   // Hover together only if URL and ID are equal.
                                                   return ([thisURL isEqual:url] && (thisId == urlId || [thisId isEqualToString:urlId]));
                                               }];
        return action;
    } else {
        return nil;
    }
}

- (void)urlActionForExistingFileWithCompletion:(void (^)(URLAction *, BOOL workingDirectoryIsLocal))completion {
    NSString *possibleFilePart1 =
        [self.prefix substringIncludingOffset:[self.prefix length] - 1
                        fromCharacterSet:[NSCharacterSet filenameCharacterSet]
                    charsTakenFromPrefix:NULL];
    NSString *possibleFilePart2 =
        [self.suffix substringIncludingOffset:0
                        fromCharacterSet:[NSCharacterSet filenameCharacterSet]
                    charsTakenFromPrefix:NULL];
    DLog(@"Prefix=%@", possibleFilePart1);
    DLog(@"Suffix=%@", possibleFilePart2);

    // Because path finders cache their results, this is not a disaster. Since the inputs tend to
    // be the same, whatever work was already done can be exploited this time around.
    [[NSNotificationCenter defaultCenter] postNotificationName:iTermURLActionFactoryCancelPathfinders
                                                        object:nil];

    _pathfinder = [self.semanticHistoryController pathOfExistingFileFoundWithPrefix:possibleFilePart1
                                                                        suffix:possibleFilePart2
                                                              workingDirectory:self.workingDirectory
                                                                trimWhitespace:NO
                                                                    completion:^(NSString *filename,
                                                                                 int prefixChars,
                                                                                 int suffixChars,
                                                                                 BOOL workingDirectoryIsLocal) {
        DLog(@"Semantic history controller returned filename %@ with %@ prefix and %@ suffix chars", filename, @(prefixChars), @(suffixChars));
        URLAction *action = [self urlActionForFilename:filename
                                           prefixChars:prefixChars
                                           suffixChars:suffixChars];
        completion(action, workingDirectoryIsLocal);
    }];
}

- (URLAction *)urlActionForFilename:(NSString *)filename
                        prefixChars:(int)prefixChars
                        suffixChars:(int)suffixChars {
    if (self.extractor.dataSource == nil) {
        return nil;
    }
    // Don't consider / to be a valid filename because it's useless and single/double slashes are
    // pretty common.
    if (filename.length == 0 ||
        [[filename stringByReplacingOccurrencesOfString:@"//" withString:@"/"] isEqualToString:@"/"]) {
        DLog(@"filename is bogus, reject");
        return nil;
    }

    DLog(@"Accepting filename from brute force search: %@", filename);
    // If you clicked on an existing filename, use it.
    URLAction *action = [URLAction urlActionToOpenExistingFile:filename];
    VT100GridWindowedRange range;

    if (self.prefixCoords.count > 0 && prefixChars > 0) {
        NSInteger i = MAX(0, (NSInteger)self.prefixCoords.count - prefixChars);
        range.coordRange.start = [self.prefixCoords[i] gridCoordValue];
    } else {
        // Everything is coming from the suffix (e.g., when mouse is on first char of filename)
        range.coordRange.start = [self.suffixCoords[0] gridCoordValue];
    }
    VT100GridCoord lastCoord;
    // Ensure we don't run off the end of suffixCoords if something unexpected happens.
    // Subtract 1 because the 0th index into suffixCoords corresponds to 1 suffix char being used, etc.
    NSInteger i = MIN((NSInteger)self.suffixCoords.count - 1, suffixChars - 1);
    if (i >= 0) {
        lastCoord = [self.suffixCoords[i] gridCoordValue];
    } else {
        // This shouldn't happen, but better safe than sorry
        lastCoord = [[self.prefixCoords lastObject] gridCoordValue];
    }
    range.coordRange.end = [self.extractor successorOfCoord:lastCoord];
    range.columnWindow = self.extractor.logicalWindow;
    action.range = range;

    NSString *lineNumber = nil;
    NSString *columnNumber = nil;
    action.rawFilename = filename;
    action.fullPath = [self.semanticHistoryController cleanedUpPathFromPath:filename
                                                                     suffix:[self.suffix substringFromIndex:suffixChars]
                                                           workingDirectory:self.workingDirectory
                                                        extractedLineNumber:&lineNumber
                                                               columnNumber:&columnNumber];
    action.lineNumber = lineNumber;
    action.columnNumber = columnNumber;
    action.workingDirectory = self.workingDirectory;
    return action;
}

- (URLAction *)urlActionForSmartSelection {
    // Next, see if smart selection matches anything with an action.
    VT100GridWindowedRange smartRange;
    SmartMatch *smartMatch = [self.extractor smartSelectionAt:self.coord
                                                    withRules:self.rules
                                               actionRequired:YES
                                                        range:&smartRange
                                             ignoringNewlines:!self.respectHardNewlines];
    NSArray *actions = [SmartSelectionController actionsInRule:smartMatch.rule];
    DLog(@"  Smart selection produces these actions: %@", actions);
    if (actions.count) {
        NSString *content = smartMatch.components[0];
        if (!self.respectHardNewlines) {
            content = [content stringByReplacingOccurrencesOfString:@"\n" withString:@""];
        }
        DLog(@"  Actions match this content: %@", content);
        URLAction *action = [URLAction urlActionToPerformSmartSelectionRule:smartMatch.rule
                                                                   onString:content];
        action.range = smartRange;
        ContextMenuActions value = [ContextMenuActionPrefsController actionForActionDict:actions[0]];
        action.selector = NSSelectorFromString(self.selectors[@(value)]);
        action.representedObject = [ContextMenuActionPrefsController parameterForActionDict:actions[0]
                                                                      withCaptureComponents:smartMatch.components
                                                                           workingDirectory:self.workingDirectory
                                                                                 remoteHost:self.remoteHost];
        return action;
    }
    return nil;
}

- (URLAction *)urlActionForAnyStringSemanticHistory {
    if (self.semanticHistoryController.activatesOnAnyString) {
        DLog(@"Semantic history accepts any input. Doing a smart match.");
        // Just do smart selection and let Semantic History take it.
        VT100GridWindowedRange smartRange;
        SmartMatch *smartMatch = [self.extractor smartSelectionAt:self.coord
                                                        withRules:self.rules
                                                   actionRequired:NO
                                                            range:&smartRange
                                                 ignoringNewlines:!self.respectHardNewlines];
        if (!VT100GridCoordEquals(smartRange.coordRange.start,
                                  smartRange.coordRange.end)) {
            NSString *name = smartMatch.components[0];
            DLog(@"Good enough for me. name=%@", name);
            URLAction *action = [URLAction urlActionToOpenExistingFile:name];
            action.rawFilename = name;
            action.range = smartRange;
            action.fullPath = name;
            action.workingDirectory = self.workingDirectory;
            return action;
        }
    }
    return nil;
}

- (URLAction *)urlActionForURLLike {
    NSString *joined = [self.prefix stringByAppendingString:self.suffix];
    DLog(@"Smart selection found nothing. Look for URL-like things in %@ around offset %d",
         joined, (int)[self.prefix length]);
    int prefixChars = 0;
    NSString *possibleUrl = [joined substringIncludingOffset:[self.prefix length]
                                            fromCharacterSet:[NSCharacterSet urlCharacterSet]
                                        charsTakenFromPrefix:&prefixChars];
    DLog(@"String of just permissible chars is <<%@>> with prefix length %d", possibleUrl, prefixChars);

    // Remove punctuation, parens, brackets, etc.
    NSRange rangeWithoutNearbyPunctuation = [possibleUrl rangeOfURLInString];
    if (rangeWithoutNearbyPunctuation.location == NSNotFound) {
        DLog(@"No URL found");
        return nil;
    }
    prefixChars -= rangeWithoutNearbyPunctuation.location;
    DLog(@"Range excluding punctuation is %@. Adjust prefixChars down to %d", NSStringFromRange(rangeWithoutNearbyPunctuation), prefixChars);
    NSString *stringWithoutNearbyPunctuation = [possibleUrl substringWithRange:rangeWithoutNearbyPunctuation];
    DLog(@"String without nearby punctuation: %@", stringWithoutNearbyPunctuation);

    if ([iTermAdvancedSettingsModel conservativeURLGuessing]) {
        DLog(@"Using conservative URL guessing");
        if (![self stringLooksLikeURL:stringWithoutNearbyPunctuation]) {
            DLog(@"Doesn't look URL-like to me, abort");
            return nil;
        }

        NSString *schemeRegex = @"^[a-z]+://";
        // Hostname with two components
        NSString *hostnameRegex = @"(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\\-]*[a-zA-Z0-9])\\.)+([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\\-]*[A-Za-z0-9])";
        NSString *portRegex = @"(:[1-9][0-9]{0,4})?";
        NSString *pathRegex = @"/";
        NSString *urlRegex = [NSString stringWithFormat:@"%@%@%@%@", schemeRegex, hostnameRegex, portRegex, pathRegex];
        if ([stringWithoutNearbyPunctuation rangeOfRegex:urlRegex].location != NSNotFound) {
            DLog(@"LGTM, using %@ with range %@ and prefix %d", stringWithoutNearbyPunctuation, NSStringFromRange(rangeWithoutNearbyPunctuation), prefixChars);
            return [self urlActionForString:stringWithoutNearbyPunctuation
                                      range:rangeWithoutNearbyPunctuation
                                prefixChars:prefixChars];
        }

        return nil;
    }

    DLog(@"Not using conservative URL guessing");

    const BOOL hasColon = ([stringWithoutNearbyPunctuation rangeOfString:@":"].location != NSNotFound);
    BOOL looksLikeURL;
    if (hasColon) {
        DLog(@"Has a colon, looks like a URL to me");
        // The test later on for whether an app exists to open the URL is sufficient.
        DLog(@"Contains a colon so it looks like a URL to me");
        looksLikeURL = YES;
    } else {
        // Only try to use HTTP if the string has something especially HTTP URL-like about it, such as
        // containing a slash. This helps reduce the number of random strings that are misinterpreted
        // as URLs.
        looksLikeURL = [self stringLooksLikeURL:[possibleUrl substringWithRange:rangeWithoutNearbyPunctuation]];

        if (looksLikeURL) {
            if (!self.workingDirectoryIsLocal && ![stringWithoutNearbyPunctuation containsString:@"/"]) {
                DLog(@"The working directory is not local and there's no slash in the filename or colon for a scheme, so this might be a file on a remote filesystem. Don't treat it as a URL.");
                return nil;
            }
            DLog(@"There's no colon but it seems like it could be an HTTP URL. Let's give that a try.");
            NSString *defaultScheme;
            if ([self stringIsSingleDomainWord:[self hostnameInSchemelessPossibleURL:stringWithoutNearbyPunctuation]]) {
                DLog(@"Use http because it's a single word");
                defaultScheme = @"http:";
            } else {
                defaultScheme = [[iTermAdvancedSettingsModel defaultURLScheme] stringByAppendingString:@":"];
                DLog(@"Use default scheme of %@", defaultScheme);
            }
            stringWithoutNearbyPunctuation = [defaultScheme stringByAppendingString:stringWithoutNearbyPunctuation];
        } else {
            DLog(@"Doesn't look enough like a URL to guess that it's an HTTP URL");
        }
    }

    if (looksLikeURL) {
        DLog(@"Looks like a URL. Return %@ with range %@ and prefix %d", stringWithoutNearbyPunctuation, NSStringFromRange(rangeWithoutNearbyPunctuation), prefixChars);
        // If the string contains non-ascii characters, percent escape them. URLs are limited to ASCII.
        return [self urlActionForString:stringWithoutNearbyPunctuation
                                  range:rangeWithoutNearbyPunctuation
                            prefixChars:prefixChars];
    }

    return nil;
}

- (NSString *)hostnameInSchemelessPossibleURL:(NSString *)url {
    const NSInteger index = [url rangeOfString:@"/"].location;
    if (index == NSNotFound) {
        return url;
    }
    return [url substringToIndex:index];
}

- (BOOL)stringIsSingleDomainWord:(NSString *)string {
    static NSCharacterSet *nonAlnum;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSCharacterSet *lowercase = [NSCharacterSet characterSetWithRange:NSMakeRange('a', 26)];
        NSCharacterSet *uppercase = [NSCharacterSet characterSetWithRange:NSMakeRange('A', 26)];
        NSCharacterSet *digits = [NSCharacterSet characterSetWithRange:NSMakeRange('0', 10)];
        NSMutableCharacterSet *temp = [[NSMutableCharacterSet alloc] init];
        [temp formUnionWithCharacterSet:lowercase];
        [temp formUnionWithCharacterSet:uppercase];
        [temp formUnionWithCharacterSet:digits];
        [temp invert];
        nonAlnum = temp;
    });
    return (string.length > 0 &&
            !isdigit([string characterAtIndex:0]) &&
            [string rangeOfCharacterFromSet:nonAlnum].location == NSNotFound);
}

- (URLAction *)urlActionForString:(NSString *)string
                            range:(NSRange)stringRange
                      prefixChars:(int)prefixChars {
    DLog(@"urlActionForString:%@ range:%@ prefixChars:%@", string, NSStringFromRange(stringRange), @(prefixChars));
    NSURL *url = [NSURL URLWithUserSuppliedString:string];
    DLog(@"See if I can open %@, aka %@", string, url);
    // If something can handle the scheme then we're all set.
    BOOL openable = (url &&
                     [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:url] != nil &&
                     prefixChars >= 0 &&
                     prefixChars <= self.prefix.length);

    if (openable) {
        DLog(@"%@ is openable", url);
        VT100GridWindowedRange range;
        NSInteger j = self.prefix.length - prefixChars;
        DLog(@"j=%@-%@=%@", @(self.prefix.length), @(prefixChars), @(j));
        if (j < self.prefixCoords.count) {
            DLog(@"j=%@ < self.prefixCoords.count=%@", @(j), @(self.prefixCoords.count));
            range.coordRange.start = [self.prefixCoords[j] gridCoordValue];
            DLog(@"range.coordRange.start=%@", VT100GridCoordDescription(range.coordRange.start));
        } else if (j == self.prefixCoords.count && j > 0) {
            DLog(@"j=%@ == self.prefixCoords.count && j > 0", @(j));
            range.coordRange.start = [self.extractor successorOfCoord:[self.prefixCoords[j - 1] gridCoordValue]];
            DLog(@"range.coordRange.start=%@ which is successor of last prefix coord %@",
                 VT100GridCoordDescription(range.coordRange.start),
                 VT100GridCoordDescription([self.prefixCoords[j - 1] gridCoordValue]));
        } else {
            DLog(@"prefixCoordscount=%@ j=%@", @(self.prefixCoords.count), @(j));
            return nil;
        }
        NSInteger i = stringRange.length - prefixChars;
        DLog(@"i=%@-%@=%@", @(stringRange.length), @(prefixChars), @(i));
        if (i < self.suffixCoords.count) {
            DLog(@"i < suffixCoords.count=%@", @(self.suffixCoords.count));
            range.coordRange.end = [self.suffixCoords[i] gridCoordValue];
            DLog(@"range.coordRange.end=%@", VT100GridCoordDescription([self.suffixCoords[i] gridCoordValue]));
        } else if (i > 0 && i == self.suffixCoords.count) {
            DLog(@"i == suffixCoords.count");
            range.coordRange.end = [self.extractor successorOfCoord:[self.suffixCoords[i - 1] gridCoordValue]];
            DLog(@"range.coordRange.end=%@, successor of %@",
                 VT100GridCoordDescription([self.suffixCoords[i - 1] gridCoordValue]),
                 VT100GridCoordDescription([self.suffixCoords[i] gridCoordValue]));
        } else {
            DLog(@"i=%@ suffixcoords.count=%@", @(i), @(self.suffixCoords.count));
            return nil;
        }
        range.columnWindow = self.extractor.logicalWindow;
        URLAction *action = [URLAction urlActionToOpenURL:string];
        action.range = range;
        return action;
    } else {
        DLog(@"%@ is not openable (couldn't convert it to a URL [%@] or no scheme handler",
             string, url);
    }
    return nil;
}

- (URLAction *)urlActionWithSecureCopy {
    DLog(@"Let's see if I can secure copy it. Do a smart selection");
    VT100GridWindowedRange smartRange;
    SmartMatch *smartMatch = [self.extractor smartSelectionAt:self.coord
                                                   withRules:self.rules
                                              actionRequired:NO
                                                       range:&smartRange
                                            ignoringNewlines:!self.respectHardNewlines];
    if (smartMatch) {
        DLog(@"Found a smart match");
        SCPPath *scpPath = self.pathFactory([smartMatch.components firstObject], self.coord.y);
        if (scpPath) {
            DLog(@"was able to cobble together a SCPPath of %@", scpPath);
            URLAction *action = [URLAction urlActionToSecureCopyFile:scpPath];
            action.range = smartRange;
            return action;
        }
    }

    return nil;
}

#pragma mark - Helpers

- (BOOL)stringLooksLikeURL:(NSString*)s {
    // This is much harder than it sounds.
    // [NSURL URLWithString] is supposed to do this, but it doesn't accept IDN-encoded domains like
    // http://例子.测试
    // Just about any word can be a URL in the local search path. The code that calls this prefers false
    // positives, so just make sure it's not empty and doesn't have illegal characters.
    if ([s rangeOfCharacterFromSet:[[NSCharacterSet urlCharacterSet] invertedSet]].location != NSNotFound) {
        return NO;
    }
    if ([s length] == 0) {
        return NO;
    }

    NSRange slashRange = [s rangeOfString:@"/"];
    if (slashRange.location == 0) {
        // URLs never start with a slash
        return NO;
    }
    if (slashRange.length > 0) {
        // Contains a slash but does not start with it.
        return YES;
    }

    NSString *ipRegex = @"^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$";
    if ([s rangeOfRegex:ipRegex].location != NSNotFound) {
        // IP addresses as dotted quad
        return YES;
    }

    NSString *hostnameRegex = @"^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\\-]*[a-zA-Z0-9])\\.)+([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\\-]*[A-Za-z0-9])$";
    if ([s rangeOfRegex:hostnameRegex].location != NSNotFound) {
        // A hostname with at least two components.
        return YES;
    }

    return NO;
}

#pragma mark - Notifications

- (void)cancelPathfinders:(NSNotification *)notification {
    [_pathfinder cancel];
}

@end


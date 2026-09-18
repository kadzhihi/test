#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <xpc/xpc.h>

extern xpc_object_t _CFXPCCreateXPCMessageWithCFObject(CFTypeRef object);
extern CFTypeRef _CFXPCCreateCFObjectFromXPCMessage(xpc_object_t object);

static const NSTimeInterval kShortTimeout = 2.5;
static const NSTimeInterval kEvalTimeout = 8.0;

static void PrintJSON(id object)
{
    if (!object) object = @{@"ok": @NO, @"error": @"nil"};

    NSData *data = nil;
    if ([NSJSONSerialization isValidJSONObject:object]) {
        data = [NSJSONSerialization dataWithJSONObject:object
                                               options:NSJSONWritingSortedKeys
                                                 error:nil];
    }

    if (!data) {
        object = @{
            @"ok": @YES,
            @"value": [object description] ?: @""
        };
        data = [NSJSONSerialization dataWithJSONObject:object
                                               options:NSJSONWritingSortedKeys
                                                 error:nil];
    }

    fwrite(data.bytes, 1, data.length, stdout);
    fwrite("\n", 1, 1, stdout);
    fflush(stdout);
}

static id DecodeXPCObject(xpc_object_t event)
{
    if (!event) return nil;

    xpc_type_t type = xpc_get_type(event);

    if (type == XPC_TYPE_ERROR) {
        const char *desc = xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION);
        return @{
            @"__xpc_error": desc ? [NSString stringWithUTF8String:desc] : @"unknown"
        };
    }

    // Form A: the event itself is a CoreFoundation object bridged through XPC.
    CFTypeRef cf = _CFXPCCreateCFObjectFromXPCMessage(event);
    if (cf) {
        return CFBridgingRelease(cf);
    }

    // Form B: WebKit-style wrapper containing a CF/XPC payload under "msgData".
    if (type == XPC_TYPE_DICTIONARY) {
        xpc_object_t inner = xpc_dictionary_get_value(event, "msgData");
        if (inner) {
            CFTypeRef innerCF = _CFXPCCreateCFObjectFromXPCMessage(inner);
            if (innerCF) {
                return CFBridgingRelease(innerCF);
            }
        }
    }

    return nil;
}

@interface WIRClient : NSObject
@property(nonatomic, strong) NSCondition *condition;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *messages;
@property(nonatomic, copy) NSString *connectionID;
@property(nonatomic, copy) NSString *serviceName;
@property(nonatomic, assign) BOOL wrappedTransport;
@property(nonatomic, assign) BOOL connected;
@property(nonatomic) xpc_connection_t connection;
@property(nonatomic) dispatch_queue_t queue;
@end

@implementation WIRClient

- (instancetype)init
{
    self = [super init];
    if (self) {
        _condition = [NSCondition new];
        _messages = [NSMutableArray array];
        _connectionID = [NSUUID.UUID.UUIDString uppercaseString];
        _queue = dispatch_queue_create("com.ioscontrol.safarijs.xpc", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)appendMessage:(NSDictionary *)message
{
    if (![message isKindOfClass:[NSDictionary class]]) return;

    [self.condition lock];
    [self.messages addObject:message];
    [self.condition broadcast];
    [self.condition unlock];
}

- (BOOL)connectService:(NSString *)service wrapped:(BOOL)wrapped
{
    self.serviceName = service;
    self.wrappedTransport = wrapped;

    self.connection =
        xpc_connection_create_mach_service(
            service.UTF8String,
            self.queue,
            0
        );

    if (!self.connection) {
        return NO;
    }

    __weak typeof(self) weakSelf = self;

    xpc_connection_set_event_handler(
        self.connection,
        ^(xpc_object_t event) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;

            id decoded = DecodeXPCObject(event);

            if ([decoded isKindOfClass:[NSDictionary class]]) {
                [self appendMessage:decoded];
            }
        }
    );

    xpc_connection_resume(self.connection);
    self.connected = YES;
    return YES;
}

- (void)disconnect
{
    if (self.connection) {
        xpc_connection_cancel(self.connection);
        self.connection = nil;
    }
    self.connected = NO;
}

- (BOOL)sendSelector:(NSString *)selector arguments:(NSDictionary *)arguments
{
    if (!self.connected || !self.connection) return NO;

    NSMutableDictionary *args =
        [NSMutableDictionary dictionaryWithDictionary:arguments ?: @{}];

    args[@"WIRConnectionIdentifierKey"] = self.connectionID;

    NSDictionary *rpc = @{
        @"__selector": selector ?: @"",
        @"__argument": args
    };

    xpc_object_t encoded =
        _CFXPCCreateXPCMessageWithCFObject(
            (__bridge CFTypeRef)rpc
        );

    if (!encoded) return NO;

    if (self.wrappedTransport) {
        xpc_object_t wrapper = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_value(wrapper, "msgData", encoded);
        xpc_connection_send_message(self.connection, wrapper);
    } else {
        xpc_connection_send_message(self.connection, encoded);
    }

    return YES;
}

- (NSArray<NSDictionary *> *)snapshotMessages
{
    [self.condition lock];
    NSArray *copy = [self.messages copy];
    [self.condition unlock];
    return copy;
}

- (NSArray<NSDictionary *> *)waitForMessagesAfter:(NSUInteger)offset
                                          timeout:(NSTimeInterval)timeout
{
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:timeout];

    [self.condition lock];

    while (self.messages.count <= offset) {
        if (![self.condition waitUntilDate:limit]) {
            break;
        }
    }

    NSArray *slice = @[];

    if (self.messages.count > offset) {
        slice =
            [self.messages subarrayWithRange:
                NSMakeRange(offset, self.messages.count - offset)];
    }

    [self.condition unlock];
    return slice;
}

@end

static NSString *SelectorOf(NSDictionary *message)
{
    id value = message[@"__selector"];
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSDictionary *ArgumentOf(NSDictionary *message)
{
    id value = message[@"__argument"];
    return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

static NSString *StringValue(id value)
{
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return nil;
}

static NSDictionary *JSONObjectFromMessageData(id value)
{
    NSData *data = nil;

    if ([value isKindOfClass:[NSData class]]) {
        data = value;
    } else if ([value isKindOfClass:[NSString class]]) {
        data = [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding];
    }

    if (!data.length) return nil;

    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static NSString *JSONString(id obj)
{
    if (!obj || ![NSJSONSerialization isValidJSONObject:obj]) return nil;

    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return nil;

    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static WIRClient *ConnectWorkingTransport(NSMutableArray *attempts)
{
    NSArray<NSString *> *services = @[
        @"com.apple.webinspector.debugger",
        @"com.apple.webinspector"
    ];

    for (NSString *service in services) {
        for (NSNumber *wrappedValue in @[@NO, @YES]) {
            BOOL wrapped = wrappedValue.boolValue;

            WIRClient *client = [WIRClient new];

            if (![client connectService:service wrapped:wrapped]) {
                [attempts addObject:@{
                    @"service": service,
                    @"wrapped": @(wrapped),
                    @"connected": @NO
                }];
                continue;
            }

            NSUInteger before = client.snapshotMessages.count;

            [client sendSelector:@"_rpc_reportIdentifier:"
                       arguments:@{}];

            [client sendSelector:@"_rpc_getConnectedApplications:"
                       arguments:@{}];

            NSArray *newMessages =
                [client waitForMessagesAfter:before
                                     timeout:kShortTimeout];

            BOOL useful = NO;
            NSString *error = nil;

            for (NSDictionary *message in newMessages) {
                if (message[@"__xpc_error"]) {
                    error = StringValue(message[@"__xpc_error"]);
                    continue;
                }

                NSString *selector = SelectorOf(message);

                if ([selector hasPrefix:@"_rpc_"]) {
                    useful = YES;
                    break;
                }
            }

            [attempts addObject:@{
                @"service": service,
                @"wrapped": @(wrapped),
                @"connected": @YES,
                @"usefulReply": @(useful),
                @"messageCount": @(newMessages.count),
                @"error": error ?: [NSNull null]
            }];

            if (useful) {
                return client;
            }

            [client disconnect];
        }
    }

    return nil;
}

static void MergeApplicationsFromMessages(
    NSArray<NSDictionary *> *messages,
    NSMutableDictionary<NSString *, NSMutableDictionary *> *apps
)
{
    for (NSDictionary *message in messages) {
        NSString *selector = SelectorOf(message);
        NSDictionary *arg = ArgumentOf(message);

        if ([selector isEqualToString:@"_rpc_reportConnectedApplicationList:"]) {
            NSDictionary *dict = arg[@"WIRApplicationDictionaryKey"];

            if ([dict isKindOfClass:[NSDictionary class]]) {
                [dict enumerateKeysAndObjectsUsingBlock:
                    ^(id key, id obj, BOOL *stop) {
                        (void)stop;

                        if (![obj isKindOfClass:[NSDictionary class]]) return;

                        NSMutableDictionary *copy =
                            [NSMutableDictionary dictionaryWithDictionary:obj];

                        NSString *appID =
                            StringValue(copy[@"WIRApplicationIdentifierKey"])
                            ?: StringValue(key);

                        if (appID.length) {
                            copy[@"WIRApplicationIdentifierKey"] = appID;
                            apps[appID] = copy;
                        }
                    }
                ];
            }
        }

        if ([selector isEqualToString:@"_rpc_applicationConnected:"] ||
            [selector isEqualToString:@"_rpc_applicationUpdated:"]) {

            NSString *appID =
                StringValue(arg[@"WIRApplicationIdentifierKey"]);

            if (appID.length) {
                NSMutableDictionary *copy =
                    [NSMutableDictionary dictionaryWithDictionary:arg];
                apps[appID] = copy;
            }
        }

        if ([selector isEqualToString:@"_rpc_applicationDisconnected:"]) {
            NSString *appID =
                StringValue(arg[@"WIRApplicationIdentifierKey"]);

            if (appID.length) {
                [apps removeObjectForKey:appID];
            }
        }
    }
}

static NSDictionary *CollectState(WIRClient *client, NSTimeInterval timeout)
{
    NSMutableDictionary<NSString *, NSMutableDictionary *> *apps =
        [NSMutableDictionary dictionary];

    NSUInteger offset = client.snapshotMessages.count;

    [client sendSelector:@"_rpc_reportIdentifier:" arguments:@{}];
    [client sendSelector:@"_rpc_getConnectedApplications:" arguments:@{}];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

    while ([deadline timeIntervalSinceNow] > 0) {
        NSArray *batch =
            [client waitForMessagesAfter:offset timeout:0.35];

        offset += batch.count;
        MergeApplicationsFromMessages(batch, apps);

        if (apps.count > 0) break;
    }

    NSMutableDictionary<NSString *, NSDictionary *> *pages =
        [NSMutableDictionary dictionary];

    NSArray<NSString *> *appIDs = apps.allKeys;

    for (NSString *appID in appIDs) {
        NSUInteger before = client.snapshotMessages.count;

        [client sendSelector:@"_rpc_forwardGetListing:"
                   arguments:@{
                       @"WIRApplicationIdentifierKey": appID
                   }];

        NSDate *listDeadline =
            [NSDate dateWithTimeIntervalSinceNow:1.0];

        while ([listDeadline timeIntervalSinceNow] > 0) {
            NSArray *batch =
                [client waitForMessagesAfter:before timeout:0.20];

            before += batch.count;
            MergeApplicationsFromMessages(batch, apps);

            BOOL gotListing = NO;

            for (NSDictionary *message in batch) {
                NSString *selector = SelectorOf(message);
                NSDictionary *arg = ArgumentOf(message);

                if (![selector isEqualToString:@"_rpc_applicationSentListing:"]) {
                    continue;
                }

                NSString *listingAppID =
                    StringValue(arg[@"WIRApplicationIdentifierKey"]);

                if (![listingAppID isEqualToString:appID]) {
                    continue;
                }

                NSDictionary *listing = arg[@"WIRListingKey"];

                if ([listing isKindOfClass:[NSDictionary class]]) {
                    pages[appID] = listing;
                } else {
                    pages[appID] = @{};
                }

                gotListing = YES;
                break;
            }

            if (gotListing) break;
        }
    }

    return @{
        @"apps": apps,
        @"pages": pages
    };
}

static NSDictionary *ChooseSafariPage(NSDictionary *state)
{
    NSDictionary *apps = state[@"apps"];
    NSDictionary *allPages = state[@"pages"];

    NSMutableSet<NSString *> *safariAppIDs = [NSMutableSet set];

    [apps enumerateKeysAndObjectsUsingBlock:
        ^(NSString *appID, NSDictionary *app, BOOL *stop) {
            (void)stop;

            NSString *bundle =
                StringValue(app[@"WIRApplicationBundleIdentifierKey"]);

            NSString *name =
                StringValue(app[@"WIRApplicationNameKey"]);

            if ([bundle isEqualToString:@"com.apple.mobilesafari"] ||
                [name localizedCaseInsensitiveContainsString:@"Safari"]) {
                [safariAppIDs addObject:appID];
            }
        }
    ];

    NSMutableArray<NSString *> *candidateApps = [NSMutableArray array];

    [apps enumerateKeysAndObjectsUsingBlock:
        ^(NSString *appID, NSDictionary *app, BOOL *stop) {
            (void)stop;

            NSString *bundle =
                StringValue(app[@"WIRApplicationBundleIdentifierKey"]);

            NSString *host =
                StringValue(app[@"WIRHostApplicationIdentifierKey"]);

            BOOL directSafari = [safariAppIDs containsObject:appID];
            BOOL safariChild =
                host.length && [safariAppIDs containsObject:host];

            BOOL webContent =
                [bundle containsString:@"WebKit.WebContent"];

            if (directSafari || safariChild || (webContent && safariChild)) {
                [candidateApps addObject:appID];
            }
        }
    ];

    // Safari itself first, then child WebContent processes.
    [candidateApps sortUsingComparator:
        ^NSComparisonResult(NSString *a, NSString *b) {
            BOOL aSafari = [safariAppIDs containsObject:a];
            BOOL bSafari = [safariAppIDs containsObject:b];

            if (aSafari == bSafari) return NSOrderedSame;
            return aSafari ? NSOrderedAscending : NSOrderedDescending;
        }
    ];

    for (NSString *appID in candidateApps) {
        NSDictionary *listing = allPages[appID];

        for (id pageKey in listing) {
            NSDictionary *page = listing[pageKey];
            if (![page isKindOfClass:[NSDictionary class]]) continue;

            NSString *url = StringValue(page[@"WIRURLKey"]) ?: @"";
            NSString *type = StringValue(page[@"WIRTypeKey"]) ?: @"";

            if (!url.length) continue;

            if (type.length &&
                ![type containsString:@"Web"] &&
                ![type containsString:@"Page"]) {
                continue;
            }

            NSNumber *pageID = page[@"WIRPageIdentifierKey"];

            if (![pageID respondsToSelector:@selector(integerValue)]) {
                pageID = @([StringValue(pageKey) integerValue]);
            }

            return @{
                @"appID": appID,
                @"pageID": pageID ?: @0,
                @"page": page,
                @"app": apps[appID] ?: @{}
            };
        }
    }

    return nil;
}

static NSDictionary *ResultValueFromRuntimeResponse(NSDictionary *response)
{
    NSDictionary *outerResult = response[@"result"];

    if (![outerResult isKindOfClass:[NSDictionary class]]) {
        return @{
            @"ok": @NO,
            @"error": @"Runtime.evaluate returned no result",
            @"raw": response ?: @{}
        };
    }

    if ([response[@"error"] isKindOfClass:[NSDictionary class]]) {
        return @{
            @"ok": @NO,
            @"error": response[@"error"],
            @"raw": response
        };
    }

    NSDictionary *remoteObject = outerResult[@"result"];

    if (![remoteObject isKindOfClass:[NSDictionary class]]) {
        return @{
            @"ok": @YES,
            @"result": outerResult
        };
    }

    id value = remoteObject[@"value"];
    id description = remoteObject[@"description"];
    id type = remoteObject[@"type"];

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"ok"] = @YES;
    out[@"type"] = type ?: [NSNull null];
    out[@"value"] = value ?: description ?: [NSNull null];
    out[@"remoteObject"] = remoteObject;

    if (outerResult[@"wasThrown"]) {
        out[@"wasThrown"] = outerResult[@"wasThrown"];
    }

    return out;
}

static NSDictionary *EvaluateJavaScript(
    WIRClient *client,
    NSDictionary *target,
    NSString *expression
)
{
    NSString *appID = target[@"appID"];
    NSNumber *pageID = target[@"pageID"];

    if (!appID.length || !pageID) {
        return @{@"ok": @NO, @"error": @"invalid Safari page target"};
    }

    NSString *sender = [NSUUID.UUID.UUIDString uppercaseString];

    NSUInteger offset = client.snapshotMessages.count;

    [client sendSelector:@"_rpc_forwardSocketSetup:"
               arguments:@{
                   @"WIRApplicationIdentifierKey": appID,
                   @"WIRPageIdentifierKey": pageID,
                   @"WIRSenderKey": sender,
                   @"WIRMessageDataTypeChunkSupportedKey": @0,
                   @"WIRAutomaticallyPause": @NO
               }];

    NSString *targetID = nil;

    NSDate *targetDeadline =
        [NSDate dateWithTimeIntervalSinceNow:2.5];

    while ([targetDeadline timeIntervalSinceNow] > 0 && !targetID.length) {
        NSArray *batch =
            [client waitForMessagesAfter:offset timeout:0.25];

        offset += batch.count;

        for (NSDictionary *message in batch) {
            if (![SelectorOf(message)
                    isEqualToString:@"_rpc_applicationSentData:"]) {
                continue;
            }

            NSDictionary *arg = ArgumentOf(message);
            NSDictionary *json =
                JSONObjectFromMessageData(arg[@"WIRMessageDataKey"]);

            if (!json) continue;

            if ([json[@"method"] isEqualToString:@"Target.targetCreated"]) {
                NSDictionary *info = json[@"params"][@"targetInfo"];
                NSString *candidate = StringValue(info[@"targetId"]);

                if (candidate.length) {
                    targetID = candidate;
                    break;
                }
            }
        }
    }

    NSInteger innerID = 7001;
    NSInteger outerID = 7002;

    NSDictionary *runtime = @{
        @"id": @(innerID),
        @"method": @"Runtime.evaluate",
        @"params": @{
            @"expression": expression ?: @"",
            @"returnByValue": @YES,
            @"includeCommandLineAPI": @YES,
            @"doNotPauseOnExceptionsAndMuteConsole": @NO,
            @"emulateUserGesture": @YES
        }
    };

    NSDictionary *wireJSON = runtime;

    if (targetID.length) {
        NSString *innerString = JSONString(runtime);

        wireJSON = @{
            @"id": @(outerID),
            @"method": @"Target.sendMessageToTarget",
            @"params": @{
                @"targetId": targetID,
                @"message": innerString ?: @"{}"
            }
        };
    }

    NSData *wireData =
        [NSJSONSerialization dataWithJSONObject:wireJSON
                                        options:0
                                          error:nil];

    if (!wireData) {
        return @{@"ok": @NO, @"error": @"failed to encode Runtime.evaluate"};
    }

    [client sendSelector:@"_rpc_forwardSocketData:"
               arguments:@{
                   @"WIRApplicationIdentifierKey": appID,
                   @"WIRPageIdentifierKey": pageID,
                   @"WIRSenderKey": sender,
                   @"WIRSessionIdentifierKey": sender,
                   @"WIRSocketDataKey": wireData
               }];

    NSDate *deadline =
        [NSDate dateWithTimeIntervalSinceNow:kEvalTimeout];

    while ([deadline timeIntervalSinceNow] > 0) {
        NSArray *batch =
            [client waitForMessagesAfter:offset timeout:0.35];

        offset += batch.count;

        for (NSDictionary *message in batch) {
            if (![SelectorOf(message)
                    isEqualToString:@"_rpc_applicationSentData:"]) {
                continue;
            }

            NSDictionary *arg = ArgumentOf(message);
            NSDictionary *json =
                JSONObjectFromMessageData(arg[@"WIRMessageDataKey"]);

            if (!json) continue;

            // Legacy/direct Runtime.evaluate response.
            if ([json[@"id"] integerValue] == innerID) {
                return ResultValueFromRuntimeResponse(json);
            }

            // Target-based response.
            if ([json[@"method"]
                    isEqualToString:@"Target.dispatchMessageFromTarget"]) {

                NSString *innerString =
                    StringValue(json[@"params"][@"message"]);

                if (!innerString.length) continue;

                NSData *innerData =
                    [innerString dataUsingEncoding:NSUTF8StringEncoding];

                NSDictionary *inner =
                    [NSJSONSerialization JSONObjectWithData:innerData
                                                    options:0
                                                      error:nil];

                if ([inner[@"id"] integerValue] == innerID) {
                    return ResultValueFromRuntimeResponse(inner);
                }
            }

            // Surface outer protocol errors.
            if ([json[@"id"] integerValue] == outerID &&
                [json[@"error"] isKindOfClass:[NSDictionary class]]) {
                return @{
                    @"ok": @NO,
                    @"error": json[@"error"],
                    @"targetID": targetID ?: [NSNull null],
                    @"raw": json
                };
            }
        }
    }

    return @{
        @"ok": @NO,
        @"error": @"Timed out waiting for Runtime.evaluate result",
        @"targetID": targetID ?: [NSNull null],
        @"appID": appID,
        @"pageID": pageID
    };
}

static NSString *ReadUTF8File(NSString *path)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSDictionary *PrintableState(NSDictionary *state)
{
    NSDictionary *apps = state[@"apps"] ?: @{};
    NSDictionary *pages = state[@"pages"] ?: @{};

    NSMutableArray *outApps = [NSMutableArray array];

    for (NSString *appID in apps) {
        NSDictionary *app = apps[appID];

        NSMutableArray *outPages = [NSMutableArray array];
        NSDictionary *listing = pages[appID];

        for (id key in listing) {
            NSDictionary *page = listing[key];
            if (![page isKindOfClass:[NSDictionary class]]) continue;

            [outPages addObject:@{
                @"id": page[@"WIRPageIdentifierKey"] ?: key ?: [NSNull null],
                @"title": page[@"WIRTitleKey"] ?: @"",
                @"url": page[@"WIRURLKey"] ?: @"",
                @"type": page[@"WIRTypeKey"] ?: @""
            }];
        }

        [outApps addObject:@{
            @"appID": appID,
            @"bundle": app[@"WIRApplicationBundleIdentifierKey"] ?: @"",
            @"name": app[@"WIRApplicationNameKey"] ?: @"",
            @"active": app[@"WIRIsApplicationActiveKey"] ?: [NSNull null],
            @"hostAppID": app[@"WIRHostApplicationIdentifierKey"] ?: [NSNull null],
            @"pages": outPages
        }];
    }

    return @{
        @"ok": @YES,
        @"applications": outApps
    };
}

static int RunProbe(void)
{
    NSMutableArray *attempts = [NSMutableArray array];
    WIRClient *client = ConnectWorkingTransport(attempts);

    if (!client) {
        PrintJSON(@{
            @"ok": @NO,
            @"stage": @"xpc-webinspector",
            @"error": @"No usable local Web Inspector debugger transport",
            @"attempts": attempts,
            @"hint": @"Confirm Safari > Advanced > Web Inspector is enabled. If all attempts show XPC connection invalid, the local debugger Mach service is rejecting this helper."
        });
        return 2;
    }

    PrintJSON(@{
        @"ok": @YES,
        @"stage": @"xpc-webinspector",
        @"service": client.serviceName ?: @"",
        @"wrapped": @(client.wrappedTransport),
        @"connectionID": client.connectionID ?: @"",
        @"attempts": attempts
    });

    [client disconnect];
    return 0;
}

static int RunList(void)
{
    NSMutableArray *attempts = [NSMutableArray array];
    WIRClient *client = ConnectWorkingTransport(attempts);

    if (!client) {
        PrintJSON(@{
            @"ok": @NO,
            @"stage": @"connect",
            @"error": @"Could not connect to local Web Inspector debugger service",
            @"attempts": attempts
        });
        return 2;
    }

    NSDictionary *state = CollectState(client, 3.0);
    NSMutableDictionary *out =
        [NSMutableDictionary dictionaryWithDictionary:PrintableState(state)];

    out[@"service"] = client.serviceName ?: @"";
    out[@"wrapped"] = @(client.wrappedTransport);

    PrintJSON(out);
    [client disconnect];
    return 0;
}

static int RunEval(NSString *expression)
{
    if (!expression.length) {
        PrintJSON(@{
            @"ok": @NO,
            @"error": @"JavaScript expression is empty"
        });
        return 2;
    }

    NSMutableArray *attempts = [NSMutableArray array];
    WIRClient *client = ConnectWorkingTransport(attempts);

    if (!client) {
        PrintJSON(@{
            @"ok": @NO,
            @"stage": @"connect",
            @"error": @"Could not connect to local Web Inspector debugger service",
            @"attempts": attempts
        });
        return 2;
    }

    NSDictionary *state = CollectState(client, 3.0);
    NSDictionary *target = ChooseSafariPage(state);

    if (!target) {
        PrintJSON(@{
            @"ok": @NO,
            @"stage": @"select-page",
            @"error": @"No inspectable MobileSafari page found",
            @"state": PrintableState(state),
            @"hint": @"Open Safari on a normal webpage and make sure Settings > Safari > Advanced > Web Inspector is enabled."
        });
        [client disconnect];
        return 3;
    }

    NSDictionary *result =
        EvaluateJavaScript(client, target, expression);

    NSMutableDictionary *out =
        [NSMutableDictionary dictionaryWithDictionary:result];

    out[@"service"] = client.serviceName ?: @"";
    out[@"wrapped"] = @(client.wrappedTransport);
    out[@"page"] = @{
        @"appID": target[@"appID"] ?: @"",
        @"pageID": target[@"pageID"] ?: @0,
        @"title": target[@"page"][@"WIRTitleKey"] ?: @"",
        @"url": target[@"page"][@"WIRURLKey"] ?: @""
    };

    PrintJSON(out);
    [client disconnect];

    return [result[@"ok"] boolValue] ? 0 : 4;
}

static void Usage(void)
{
    fprintf(stderr,
        "SafariJS Helper\n"
        "\n"
        "Usage:\n"
        "  safarijs probe\n"
        "  safarijs list\n"
        "  safarijs eval '<javascript>'\n"
        "  safarijs eval-file /path/to/script.js\n"
        "\n"
    );
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            Usage();
            return 1;
        }

        NSString *command =
            [NSString stringWithUTF8String:argv[1]];

        if ([command isEqualToString:@"probe"]) {
            return RunProbe();
        }

        if ([command isEqualToString:@"list"]) {
            return RunList();
        }

        if ([command isEqualToString:@"eval"]) {
            if (argc < 3) {
                Usage();
                return 1;
            }

            NSString *expression =
                [NSString stringWithUTF8String:argv[2]];

            return RunEval(expression);
        }

        if ([command isEqualToString:@"eval-file"]) {
            if (argc < 3) {
                Usage();
                return 1;
            }

            NSString *path =
                [NSString stringWithUTF8String:argv[2]];

            NSString *expression = ReadUTF8File(path);

            if (!expression) {
                PrintJSON(@{
                    @"ok": @NO,
                    @"error": @"Could not read JavaScript file",
                    @"path": path ?: @""
                });
                return 2;
            }

            return RunEval(expression);
        }

        Usage();
        return 1;
    }
}

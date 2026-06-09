#import "CTypedStreamDecode.h"

NSString *_Nullable PippinDecodeAttributedBody(NSData *data) {
    if (data.length == 0) {
        return nil;
    }
    @try {
        // NSUnarchiver is the symmetric decoder for the typedstream format
        // Messages uses; deprecated since 10.13 but still functional. Foreign or
        // truncated blobs raise an ObjC exception, which the @catch contains.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        id obj = [NSUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
        NSString *string = nil;
        if ([obj isKindOfClass:[NSAttributedString class]]) {
            string = [(NSAttributedString *)obj string];
        } else if ([obj isKindOfClass:[NSString class]]) {
            string = (NSString *)obj;
        }
        return (string.length > 0) ? string : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

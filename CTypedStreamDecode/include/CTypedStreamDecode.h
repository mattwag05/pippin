#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Decode a Messages `chat.db` `attributedBody` blob to its plain string.
///
/// Modern macOS stores message bodies in `message.attributedBody` as a
/// **typedstream** (the old `NSArchiver` format, header `\x04\x0bstreamtyped…`),
/// NOT an `NSKeyedArchiver` plist — so `NSKeyedUnarchiver` cannot read it. The
/// symmetric decoder is `NSUnarchiver` (deprecated but present), wrapped here in
/// `@try/@catch` so a malformed/foreign blob returns nil instead of crashing the
/// process with an ObjC exception Swift can't catch. (pippin-cc1)
///
/// Returns nil for an empty blob, an undecodable blob, or a blob that yields no
/// text (e.g. an attachment-only message).
NSString *_Nullable PippinDecodeAttributedBody(NSData *data);

NS_ASSUME_NONNULL_END

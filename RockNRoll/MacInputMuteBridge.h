#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Public macOS AVAudioApplication API, unavailable in iOS SDK declarations.
BOOL RockMacInputMuteAvailable(void);
BOOL RockMacInputMuteSet(BOOL muted);
BOOL RockMacInputMuteIsMuted(void);
BOOL RockMacInputMuteRegister(BOOL enabled);
NS_ASSUME_NONNULL_END

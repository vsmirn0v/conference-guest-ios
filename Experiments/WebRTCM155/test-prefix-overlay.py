#!/usr/bin/env python3
"""Pure synthetic fixtures: no source checkout copying, mutation or builds."""
import unittest
from pathlib import Path
import tempfile
import prefix_overlay as p


class PrefixOverlayTests(unittest.TestCase):
    def setUp(self):
        self.mapping = {"RTCThing": ("RTC_OBJC_TYPE", "RTCThing"),
                        "RTCInitializeSSL": ("RTC_OBJC_TYPE", "RTCInitializeSSL"),
                        "kRTCKey": ("RTC_CONSTANT_TYPE", "RTCKey")}

    def test_identifiers_preserve_imports_strings_comments_and_crlf(self):
        source = ('#import "RTCThing.h"\r\n#include <SDK/RTCThing.h>\r\n'
                  '// RTCThing kRTCKey\r\n/* RTCInitializeSSL() */\r\n'
                  'RTCThing *value; const char *s = "RTCThing \\\" kRTCKey";\r\n'
                  'NSString *s2 = @"RTCThing"; auto raw = R"tag(RTCThing \" kRTCKey)tag";\r\n'
                  'auto n = 100\'000; auto c = \'R\';\r\n'
                  'RTCInitializeSSL(); id value2 = kRTCKey;\r\n')
        result, changes = p.transform_code(source, self.mapping, "livekit")
        expected = source.replace('RTCThing *value;', 'RTC_OBJC_TYPE(RTCThing) *value;').replace(
            '\r\nRTCInitializeSSL();', '\r\nRTC_OBJC_TYPE(RTCInitializeSSL)();').replace(
            'value2 = kRTCKey;', 'value2 = RTC_CONSTANT_TYPE(RTCKey);')
        self.assertEqual(result.encode(), expected.encode())
        self.assertEqual(len(changes), 3)

    def test_wrapped_identifiers_are_not_double_wrapped(self):
        source = 'RTC_OBJC_TYPE \n (RTCThing) *x; auto key = RTC_CONSTANT_TYPE(RTCKey);'
        result, changes = p.transform_code(source, self.mapping, "livekit")
        self.assertEqual(result, source)
        self.assertEqual(changes, [])

    def test_cpp_names_are_preserved_despite_objc_name_collisions(self):
        mapping = {'RTCCertificate': ('RTC_OBJC_TYPE', 'RTCCertificate'),
                   'RTCConfiguration': ('RTC_OBJC_TYPE', 'RTCConfiguration'), **self.mapping}
        source = ('webrtc::RTCCertificate *native;\n'
                  'std::unique_ptr<webrtc::PeerConnectionInterface::RTCConfiguration> config;\n'
                  'webrtc :: RTCCertificate :: FromPEM(pem);\n'
                  'RTCConfiguration::Mode mode;\n'
                  'typename Container<T>::template RTCThing<U> nativeTemplate;\n'
                  'RTCCertificate *objc; RTCConfiguration *objcConfig;\n'
                  '::RTCInitializeSSL();\n')
        result, changes = p.transform_code(source, mapping, 'livekit')
        expected = source.replace('RTCCertificate *objc;', 'RTC_OBJC_TYPE(RTCCertificate) *objc;').replace(
            'RTCConfiguration *objcConfig;', 'RTC_OBJC_TYPE(RTCConfiguration) *objcConfig;').replace(
            '::RTCInitializeSSL();', '::RTC_OBJC_TYPE(RTCInitializeSSL)();')
        self.assertEqual(result, expected)
        self.assertEqual(len(changes), 3)

    def test_forward_declaration_argument_and_macro_body(self):
        source = ('#define RTCPass(x) ((RTCThing *)(x))\n'
                  'RTC_FWD_DECL_OBJC_CLASS(RTCThing);\n')
        result, _ = p.transform_code(source, self.mapping, "livekit")
        self.assertEqual(result, '#define RTCPass(x) ((RTC_OBJC_TYPE(RTCThing) *)(x))\n'
                         'RTC_FWD_DECL_OBJC_CLASS(RTC_OBJC_TYPE(RTCThing));\n')

    def test_new_macro_header_gets_explicit_dependency(self):
        source = ('/* SDK */\r\n#import <Foundation/Foundation.h>\r\n'
                  '@interface RTC_OBJC_TYPE(RTCThing) : NSObject @end\r\n')
        output, added = p.ensure_macro_import(source)
        self.assertTrue(added)
        self.assertEqual(output, source.replace('#import <Foundation/Foundation.h>',
                         '#import "sdk/objc/base/RTCMacros.h"\r\n#import <Foundation/Foundation.h>'))
        self.assertEqual(p.ensure_macro_import(output), (output, False))

    def test_native_consumers_include_outside_sdk_audio_adapter(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            modules = root / 'modules/audio_device'
            modules.mkdir(parents=True)
            sources = {
                'adapter.h': 'RTC_FWD_DECL_OBJC_CLASS(RTCThing);\n',
                'adapter.mm': '#import "components/audio/RTCThing.h"\nRTCThing *x;\n',
                'consumer.h': '# include "sdk/objc/base/RTCMacros.h"\nRTCThing *x;\n',
                'comment.h': '// RTC_FWD_DECL_OBJC_CLASS(RTCThing)\n',
                'native.h': 'namespace native { class RTCThing {}; }\n',
                'matlab.m': "plot(value'); % Not an Objective-C implementation\n"}
            for name, source in sources.items():
                (modules / name).write_text(source)
            self.assertEqual(p.native_consumer_paths(root),
                             {'modules/audio_device/' + name for name in ('adapter.h', 'adapter.mm', 'consumer.h')})
            mapping = {'RTCThing': ('RTC_OBJC_TYPE', 'RTCThing')}
            output, _ = p.transform_code(sources['adapter.h'], mapping, 'livekit')
            self.assertIn('RTC_FWD_DECL_OBJC_CLASS(RTC_OBJC_TYPE(RTCThing))', output)
            symbols = p.inventory({'native.mm': 'typedef int RTCNative;\n@interface RTCThing : NSObject @end\n'},
                                  objc_only=True)
            self.assertEqual(set(symbols), {'RTCThing'})

    def test_local_objc_runtime_definitions_exclude_categories_and_forwards(self):
        source = ('@interface SckHelper : NSObject @end\n'
                  '@interface ObjCAudioDeviceDelegate : NSObject @end\n'
                  '@interface UIDevice (RTCDevice) @end\n'
                  '@class AVAudioEngine; @protocol External;\n'
                  '@protocol CaptureObserver <NSObject> @end\n')
        local = p.local_objc_definitions({'consumer.mm': source})
        self.assertEqual(set(local), {'SckHelper', 'ObjCAudioDeviceDelegate', 'CaptureObserver'})
        mapping = {name: (None, entry['output']) for name, entry in local.items()}
        output, _ = p.transform_code(source + 'Cpp::SckHelper *native; SckHelper *objc;\n', mapping, 'livekit')
        self.assertIn('@interface LKSckHelper :', output)
        self.assertIn('Cpp::SckHelper *native; LKSckHelper *objc;', output)
        self.assertIn('@interface UIDevice (RTCDevice)', output)
        with self.assertRaisesRegex(ValueError, 'Ambiguous native'):
            p.reject_native_cpp_name_collisions({'native.mm': 'namespace Cpp { class SckHelper; }'}, local)

    def test_macro_dependency_repair_uses_transitive_imports(self):
        contents = {
            'sdk/objc/base/RTCMacros.h': '#define RTC_OBJC_TYPE(x) LK##x\n',
            'sdk/objc/A.h': '#import <Foundation/Foundation.h>\n@interface RTC_OBJC_TYPE(RTCA) : NSObject @end\n',
            'sdk/objc/A+Private.h': '#import "A.h"\n@interface RTC_OBJC_TYPE(RTCA) () @end\n',
            'sdk/objc/native/consumer.h': '#include "sdk/objc/A+Private.h"\nRTC_OBJC_TYPE(RTCA) *value;\n'}
        imports = p.repair_header_macro_imports(contents, set(contents) - {'sdk/objc/base/RTCMacros.h'})
        self.assertEqual(imports, ['sdk/objc/A.h'])
        self.assertNotIn('base/RTCMacros.h', contents['sdk/objc/native/consumer.h'])
        self.assertNotIn('base/RTCMacros.h', contents['sdk/objc/A+Private.h'])

    def test_error_text_is_not_lexed_as_a_character_literal(self):
        source = "#error You're building RTCThing for an unsupported target.\nRTCThing *x;\n"
        result, _ = p.transform_code(source, self.mapping, "livekit")
        self.assertEqual(result, source.replace('\nRTCThing *x;', '\nRTC_OBJC_TYPE(RTCThing) *x;'))

    def test_formal_enum_block_struct_and_internal_class_inventory(self):
        source = ('typedef NS_ENUM(NSInteger, RTCMode) { RTCModeA, RTCModeB = 2 };\n'
                  'typedef void (^RTCCallback)(RTCMode mode);\n'
                  'typedef struct { int x; int y; } RTCPoint;\n'
                  '@interface RTCNativeAudioSessionDelegateAdapter : NSObject @end\n'
                  'RTC_EXTERN NSString *const kRTCKey;\n')
        symbols = p.inventory({'fixture.h': source})
        self.assertEqual(set(symbols), {'RTCMode', 'RTCModeA', 'RTCModeB', 'RTCCallback',
                                        'RTCPoint', 'RTCNativeAudioSessionDelegateAdapter', 'RTCKey'})
        self.assertEqual(symbols['RTCKey']['kind'], 'constant')

    def test_helper_names_are_flavor_specific(self):
        source = ('@interface RTC_OBJC_TYPE(RTCConferenceYUVHelper) : NSObject @end\n'
                  '#import "RTCYUVHelper.h"\n// RTCConferenceYUVHelper\n')
        livekit, _ = p.transform_code(source, self.mapping, 'livekit')
        guest, _ = p.transform_code(source, self.mapping, 'guest')
        self.assertIn('RTC_OBJC_TYPE(RTCYUVHelper)', livekit)
        self.assertIn('// RTCConferenceYUVHelper', livekit)
        self.assertEqual(guest, source)

    def test_prefix_definitions_and_reapplication_guard(self):
        source = ('#ifndef RTC_OBJC_TYPE_PREFIX\n#define RTC_OBJC_TYPE_PREFIX\n#endif\n'
                  '#ifndef RTC_CONSTANT_TYPE_PREFIX\n#define RTC_CONSTANT_TYPE_PREFIX k\n#endif\n')
        result = p.macro_prefix(source, 'livekit')
        self.assertIn('#define RTC_OBJC_TYPE_PREFIX LK\n', result)
        self.assertIn('#define RTC_CONSTANT_TYPE_PREFIX kLK\n', result)
        with self.assertRaisesRegex(ValueError, 'already has'):
            p.macro_prefix(result, 'livekit')
        self.assertEqual(p.macro_prefix(source, 'guest'), source)

    def test_custom_c_exports_are_isolated_only_in_livekit(self):
        source = ('RTC_EXTERN int RTCConfigureScreenShareEncoderQuality(void *x, int qp, int speed);\n'
                  'RTC_EXTERN int RTCSetScreenShareSenderResolution(void *x, const char *track);\n'
                  'RTC_EXTERN void RTCEnableMetrics(void);\n'
                  'RTC_EXTERN BOOL RTCInitializeSSL(void);\n')
        current = p.raw_c_functions({'fixture.h': source})
        legacy = p.raw_c_functions({'fixture.h': 'RTC_EXTERN void RTCEnableMetrics(void);'})
        qualified = {'RTCEnableMetrics', 'LKRTCInitializeSSL'}
        isolated = p.export_isolation(current, legacy, qualified, 'livekit', {'RTCInitializeSSL'})
        self.assertEqual(set(isolated), {'RTCConfigureScreenShareEncoderQuality',
                                         'RTCSetScreenShareSenderResolution'})
        mapping = dict(self.mapping)
        mapping.update({name: ('RTC_OBJC_TYPE', name) for name in isolated})
        result, _ = p.transform_code(source, mapping, 'livekit')
        self.assertIn('int RTC_OBJC_TYPE(RTCConfigureScreenShareEncoderQuality)(', result)
        self.assertIn('int RTC_OBJC_TYPE(RTCSetScreenShareSenderResolution)(', result)
        self.assertIn('void RTCEnableMetrics(', result)
        self.assertIn('BOOL RTC_OBJC_TYPE(RTCInitializeSSL)(', result)
        self.assertEqual(p.export_isolation(current, legacy, set(), 'guest'), {})
        guest, _ = p.transform_code(source, self.mapping, 'guest')
        self.assertEqual(guest, source.replace('BOOL RTCInitializeSSL(', 'BOOL RTC_OBJC_TYPE(RTCInitializeSSL)('))
        use = 'int RTCConfigureScreenShareEncoderQuality(void *x) { return RTCConfigureScreenShareEncoderQuality(x); }\n'
        transformed, _ = p.transform_code(use, mapping, 'livekit')
        self.assertEqual(transformed.count('RTC_OBJC_TYPE(RTCConfigureScreenShareEncoderQuality)'), 2)

    def test_unqualified_binary_export_inventory_is_rejected(self):
        current = {'RTCAdded': [], 'RTCEnableMetrics': []}
        legacy = {'RTCEnableMetrics': []}
        with self.assertRaisesRegex(ValueError, 'lacks legacy'):
            p.export_isolation(current, legacy, set(), 'livekit')
        with self.assertRaisesRegex(ValueError, 'guest-only'):
            p.export_isolation(current, legacy, set(current), 'livekit')

    def test_packaging_changes_are_field_scoped(self):
        source = ('output_name = "WebRTC"\noutput_name = "WebRTC"\n'
                  'sources = [ "$root_build_dir/WebRTC.framework" ]\n'
                  'sources = [ "$root_build_dir/WebRTC.framework" ]\n'
                  '# WebRTC RTCThing\nother = "WebRTC"\n')
        result = p.packaging(source, 'sdk/BUILD.gn')
        self.assertEqual(result.count('output_name = "LiveKitWebRTC"'), 2)
        self.assertIn('other = "WebRTC"', result)
        self.assertIn('# WebRTC RTCThing', result)
        with self.assertRaises(ValueError):
            p.packaging(source.replace('output_name', 'unexpected', 1), 'sdk/BUILD.gn')

    def test_python_packaging_preserves_unrelated_strings_and_comments(self):
        source = ('# WebRTC documentation\n'
                  'message = "WebRTC"\n'
                  'def output(s):\n'
                  '    return "#import <WebRTC/{}>\\n".format(s)\n')
        result = p.packaging(source, 'tools_webrtc/ios/generate_umbrella_header.py')
        self.assertIn('# WebRTC documentation', result)
        self.assertIn('message = "WebRTC"', result)
        self.assertIn('#import <LiveKitWebRTC/{}>', result)


if __name__ == '__main__':
    unittest.main()

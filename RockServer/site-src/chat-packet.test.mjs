import assert from 'node:assert/strict';
import { encodeChat, decodeChat } from './chat-packet.js';
for (const text of ['a'.repeat(2000), '字'.repeat(2000), '🎸'.repeat(2000), 'e\u0301'.repeat(1000), '"\\\n'.repeat(666)]) {
  assert.equal(decodeChat(encodeChat({id:'12345678-1234-1234-1234-123456789abc',text})).text, text);
}
assert.throws(() => encodeChat({id:'a'.repeat(65), text:'test'}));
assert.throws(() => encodeChat({id:'id', text:'🎸'.repeat(2001)}));
assert.throws(() => decodeChat(new Uint8Array(16385)));
console.log('Browser chat contract tests passed');

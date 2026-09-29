export const chatTopic = 'rock.chat.v1';
export const maximumChatBytes = 16384;
const encoder = new TextEncoder();
export function encodeChat(packet) {
  if (typeof packet?.id !== 'string' || !packet.id || encoder.encode(packet.id).length > 64 ||
      typeof packet.text !== 'string' || !packet.text || [...packet.text].length > 2000) {
    throw new Error('This message is too long to send. Shorten it and try again.');
  }
  const bytes = encoder.encode(JSON.stringify(packet));
  if (bytes.length > maximumChatBytes) throw new Error('This message is too large to send.');
  return bytes;
}
export function decodeChat(bytes) {
  if (bytes.byteLength > maximumChatBytes) throw new Error('Message exceeds the packet limit.');
  const packet = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes));
  encodeChat(packet);
  return packet;
}

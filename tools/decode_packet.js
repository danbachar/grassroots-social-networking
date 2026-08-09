#!/usr/bin/env node

// Decode a GrassrootsPacket from a byte array.
//
// Wire format (lib/src/models/packet.dart, header = 58 bytes):
//   type(1) + ttl(1) + timestamp u32 BE(4) + recipient pubkey(32, zeros =
//   broadcast) + packetId UUID(16) + payloadLength u32 BE(4) + payload
//
// The outer envelope deliberately carries NO sender and NO signature —
// sender identity and authentication live inside the Noise-sealed payload
// (ANNOUNCE is the one exception: its payload embeds the pubkey and a
// trailing Ed25519 signature; see lib/src/protocol/protocol_handler.dart).
//
// Usage: node decode_packet.js '[1, 7, 105, ...]'
// Or paste the array when prompted

const PACKET_TYPES = {
  0x01: 'ANNOUNCE',
  0x02: 'NOISE_HANDSHAKE',
  0x03: 'SECURE',
};

const HEADER_SIZE = 58;
const SIGNATURE_SIZE = 64;

function toHex(bytes) {
  return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
}

function bytesToUuid(bytes) {
  const hex = toHex(bytes);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

function readUint16BE(data, offset) {
  return (data[offset] << 8) | data[offset + 1];
}

function readUint32BE(data, offset) {
  return ((data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3]) >>> 0;
}

function isAllZeros(bytes) {
  return bytes.every(b => b === 0);
}

function decodeAnnouncePayload(payload) {
  // Format: [pubkey(32) + version(2) + platform(1) + flags(1) + nickLen(1)
  //          + nick + candidateCount(2) + repeated(candidateLen(2) + candidate)
  //          + signature(64)]
  let offset = 0;

  const pubkey = payload.slice(offset, offset + 32);
  offset += 32;

  const version = readUint16BE(payload, offset);
  offset += 2;

  const platform = payload[offset] === 1 ? 'ios' : 'other';
  offset += 1;

  const flags = payload[offset];
  const willingToFacilitate = (flags & 0x01) !== 0;
  offset += 1;

  const nickLen = payload[offset];
  offset += 1;

  const nickname = new TextDecoder().decode(new Uint8Array(payload.slice(offset, offset + nickLen)));
  offset += nickLen;

  const candidates = [];
  if (offset + 2 <= payload.length) {
    const candidateCount = readUint16BE(payload, offset);
    offset += 2;
    for (let i = 0; i < candidateCount; i++) {
      if (offset + 2 > payload.length) break;
      const candidateLen = readUint16BE(payload, offset);
      offset += 2;
      if (offset + candidateLen > payload.length) break;
      candidates.push(new TextDecoder().decode(new Uint8Array(payload.slice(offset, offset + candidateLen))));
      offset += candidateLen;
    }
  }

  const signature = payload.slice(payload.length - SIGNATURE_SIZE);

  console.log('  --- ANNOUNCE Payload ---');
  console.log(`  Pubkey:     ${toHex(pubkey)}`);
  console.log(`  Version:    ${version}`);
  console.log(`  Platform:   ${platform}`);
  console.log(`  Facilitate: ${willingToFacilitate}`);
  console.log(`  Nickname:   "${nickname}" (${nickLen} bytes)`);
  if (candidates.length > 0) {
    candidates.forEach((c, i) => console.log(`  Candidate:  [${i}] ${c}`));
  } else {
    console.log('  Candidates: (none)');
  }
  console.log(`  Signature:  ${toHex(signature.slice(0, 8))}... (Ed25519 over the body)`);
}

function decodePacket(bytes) {
  if (bytes.length < HEADER_SIZE) {
    console.error(`Packet too small: ${bytes.length} < ${HEADER_SIZE}`);
    console.log('\nRaw bytes as UTF-8:', new TextDecoder().decode(new Uint8Array(bytes)));
    return;
  }

  let offset = 0;

  // Type (1 byte)
  const typeValue = bytes[offset++];
  const typeName = PACKET_TYPES[typeValue] || `UNKNOWN(0x${typeValue.toString(16)})`;

  // TTL (1 byte)
  const ttl = bytes[offset++];

  // Timestamp (4 bytes, big-endian, seconds)
  const timestamp = readUint32BE(bytes, offset);
  offset += 4;
  const date = new Date(timestamp * 1000);

  // Recipient pubkey (32 bytes, all-zeros = broadcast). No sender on the
  // wire — relays must not learn who originated a packet.
  const recipientPubkey = bytes.slice(offset, offset + 32);
  const isBroadcast = isAllZeros(recipientPubkey);
  offset += 32;

  // Packet ID (16 bytes UUID)
  const packetIdBytes = bytes.slice(offset, offset + 16);
  const packetId = bytesToUuid(packetIdBytes);
  offset += 16;

  // Payload length (4 bytes, big-endian)
  const payloadLength = readUint32BE(bytes, offset);
  offset += 4;

  // Payload
  const payload = bytes.slice(offset, offset + payloadLength);

  console.log('=== GrassrootsPacket ===');
  console.log(`Type:        ${typeName} (0x${typeValue.toString(16).padStart(2, '0')})`);
  console.log(`TTL:         ${ttl}`);
  console.log(`Timestamp:   ${timestamp} (${date.toISOString()})`);
  console.log(`Recipient:   ${isBroadcast ? '(broadcast)' : toHex(recipientPubkey)}`);
  console.log(`Packet ID:   ${packetId}`);
  console.log(`Payload len: ${payloadLength}`);
  console.log(`Total bytes: ${bytes.length} (header: ${HEADER_SIZE}, payload: ${payloadLength})`);

  if (payload.length > 0) {
    console.log('');

    if (typeName === 'ANNOUNCE') {
      decodeAnnouncePayload(payload);
    } else {
      // NOISE_HANDSHAKE / SECURE payloads are sealed bytes — nothing to
      // decode without the session keys.
      console.log(`  --- ${typeName} Payload (sealed) ---`);
      console.log(`  Hex:  ${toHex(payload)}`);
    }
  }
}

// --- Main ---

function parseInput(input) {
  // Strip surrounding brackets and whitespace
  input = input.trim().replace(/^\[/, '').replace(/\]$/, '');
  return input.split(',').map(s => parseInt(s.trim(), 10)).filter(n => !isNaN(n));
}

const arg = process.argv.slice(2).join(' ');
if (arg) {
  decodePacket(parseInput(arg));
} else {
  // Read from stdin
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => data += chunk);
  process.stdin.on('end', () => {
    if (data.trim()) {
      decodePacket(parseInput(data));
    } else {
      console.log('Usage: node decode_packet.js \'[1, 7, 105, ...]\'');
      console.log('   or: echo \'[1, 7, ...]\' | node decode_packet.js');
    }
  });
}

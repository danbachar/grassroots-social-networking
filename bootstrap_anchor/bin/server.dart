import 'dart:io';
import 'package:bootstrap_anchor/bootstrap_anchor.dart';
import 'package:args/args.dart';

void main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('seed',
        abbr: 's',
        help: 'Anchor seed hex (64 chars). Derived from the owner\'s key via:\n'
            '  anchorSeed = SHA-256(ownerSeed || "bitchat-anchor")\n'
            'The owner\'s device can export this with identity.anchorSeed.',
        mandatory: true)
    ..addOption('owner',
        abbr: 'o',
        help: 'Owner pubkey hex (64 chars). Only this peer can push FRIENDS_SYNC.',
        mandatory: true)
    ..addOption('port', abbr: 'p', defaultsTo: '9514', help: 'UDP port to bind')
    ..addOption('nickname', abbr: 'n', defaultsTo: 'anchor', help: 'Server nickname for ANNOUNCE')
    ..addOption('friends',
        abbr: 'f',
        defaultsTo: 'friends.json',
        help: 'Path to friends list file (restart recovery)')
    ..addOption('announce-interval',
        defaultsTo: '30', help: 'ANNOUNCE interval in seconds')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    print('Error: $e\n');
    print('Bitchat Bootstrap Anchor Server\n');
    print(parser.usage);
    exit(1);
  }

  if (results['help'] as bool) {
    print('Bitchat Bootstrap Anchor Server');
    print('');
    print('A personal cloud peer that acts as a well-connected friend.');
    print('It belongs to a specific owner and only serves their friends.');
    print('');
    print('The server\'s identity is a subkey of the owner\'s key:');
    print('  anchorSeed = SHA-256(ownerSeed || "bitchat-anchor")');
    print('');
    print('Usage:');
    print('  bootstrap_anchor --seed <anchor_seed_hex> --owner <owner_pubkey_hex> [options]');
    print('');
    print(parser.usage);
    print('');
    print('Getting the seed:');
    print('  On the owner\'s device, call identity.anchorSeed to export the');
    print('  32-byte hex seed. This is the only secret the server needs.');
    exit(0);
  }

  final seedHex = results['seed'] as String;
  if (seedHex.length != 64 || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(seedHex)) {
    print('Error: --seed must be a 64-character hex string (32 bytes)');
    exit(1);
  }

  final ownerPubkey = results['owner'] as String;
  if (ownerPubkey.length != 64 || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(ownerPubkey)) {
    print('Error: --owner must be a 64-character hex public key');
    exit(1);
  }

  final port = int.parse(results['port'] as String);
  final nickname = results['nickname'] as String;
  final friendsPath = results['friends'] as String;
  final announceInterval = int.parse(results['announce-interval'] as String);

  // Create a default friends.json if it doesn't exist
  if (!File(friendsPath).existsSync()) {
    print('Creating default $friendsPath (empty friend list)');
    File(friendsPath).writeAsStringSync('{\n  "friends": []\n}\n');
  }

  final server = AnchorServer(
    port: port,
    nickname: nickname,
    seedHex: seedHex,
    friendsPath: friendsPath,
    ownerPubkeyHex: ownerPubkey,
    announceIntervalSeconds: announceInterval,
  );

  // Graceful shutdown
  ProcessSignal.sigint.watch().listen((_) async {
    print('\nShutting down...');
    await server.stop();
    exit(0);
  });
  ProcessSignal.sigterm.watch().listen((_) async {
    print('\nShutting down...');
    await server.stop();
    exit(0);
  });

  await server.start();
}

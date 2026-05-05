import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/store/friendships_state.dart';
import 'package:grassroots_networking/src/store/friendships_actions.dart';
import 'package:grassroots_networking/src/store/friendships_reducer.dart';

void main() {
  const peerA = 'aabbccdd11223344aabbccdd11223344aabbccdd11223344aabbccdd11223344';
  const peerB = 'eeff00112233445566778899aabbccddeeff00112233445566778899aabbccdd';

  group('friendshipsReducer', () {
    group('CreateFriendRequestAction', () {
      test('creates friendship with status pending', () {
        const state = FriendshipsState.initial;
        final action = CreateFriendRequestAction(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          message: 'Hey, let\'s be friends!',
        );

        final newState = friendshipsReducer(state, action);

        expect(newState.friendships.containsKey(peerA), isTrue);
        final friendship = newState.friendships[peerA]!;
        expect(friendship.peerPubkeyHex, equals(peerA));
        expect(friendship.status, equals(FriendshipStatus.pending));
        expect(friendship.isPendingOutgoing, isTrue);
        expect(friendship.nickname, equals('Alice'));
        expect(friendship.message, equals('Hey, let\'s be friends!'));
        expect(friendship.createdAt, isNotNull);
        expect(friendship.updatedAt, isNotNull);
      });

      test('sets timestamps on creation', () {
        final before = DateTime.now();
        const state = FriendshipsState.initial;
        final action = CreateFriendRequestAction(
          peerPubkeyHex: peerA,
        );

        final newState = friendshipsReducer(state, action);
        final after = DateTime.now();

        final friendship = newState.friendships[peerA]!;
        expect(friendship.createdAt.isAfter(before) || friendship.createdAt.isAtSameMomentAs(before), isTrue);
        expect(friendship.createdAt.isBefore(after) || friendship.createdAt.isAtSameMomentAs(after), isTrue);
        expect(friendship.updatedAt, equals(friendship.createdAt));
      });
    });

    group('ReceiveFriendRequestAction', () {
      test('creates new friendship with status received for incoming request', () {
        const state = FriendshipsState.initial;
        final action = ReceiveFriendRequestAction(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          message: 'Add me!',
        );

        final newState = friendshipsReducer(state, action);

        expect(newState.friendships.containsKey(peerA), isTrue);
        final friendship = newState.friendships[peerA]!;
        expect(friendship.status, equals(FriendshipStatus.received));
        expect(friendship.isPendingIncoming, isTrue);
        expect(friendship.nickname, equals('Alice'));
        expect(friendship.message, equals('Add me!'));
      });

      test('auto-accepts mutual request when we already have pending outgoing', () {
        // We already sent a friend request to peerA (status=pending)
        final now = DateTime.now();
        final existingFriendship = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          status: FriendshipStatus.pending,
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: existingFriendship},
        );

        // Now we receive a friend request from peerA
        final action = ReceiveFriendRequestAction(
          peerPubkeyHex: peerA,
          nickname: 'Alice Updated',
        );

        final newState = friendshipsReducer(state, action);

        final friendship = newState.friendships[peerA]!;
        expect(friendship.status, equals(FriendshipStatus.accepted));
        expect(friendship.isAccepted, isTrue);
        expect(friendship.nickname, equals('Alice Updated'));
      });

      test('auto-accept preserves existing nickname when incoming nickname is null', () {
        final now = DateTime.now();
        final existingFriendship = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          status: FriendshipStatus.pending,
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: existingFriendship},
        );

        final action = ReceiveFriendRequestAction(
          peerPubkeyHex: peerA,
          nickname: null,
        );

        final newState = friendshipsReducer(state, action);

        final friendship = newState.friendships[peerA]!;
        expect(friendship.status, equals(FriendshipStatus.accepted));
        expect(friendship.nickname, equals('Alice'));
      });

      test('updates nickname for already-accepted friendships', () {
        final now = DateTime.now();
        final existingFriendship = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          status: FriendshipStatus.accepted,
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: existingFriendship},
        );

        final action = ReceiveFriendRequestAction(
          peerPubkeyHex: peerA,
          nickname: 'Alice New Name',
        );

        final newState = friendshipsReducer(state, action);

        final friendship = newState.friendships[peerA]!;
        expect(friendship.status, equals(FriendshipStatus.accepted));
        expect(friendship.nickname, equals('Alice New Name'));
      });
    });

    group('AcceptFriendRequestAction', () {
      test('changes status from received to accepted', () {
        final now = DateTime.now();
        final existingFriendship = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          status: FriendshipStatus.received,
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: existingFriendship},
        );

        final action = AcceptFriendRequestAction(peerA);

        final newState = friendshipsReducer(state, action);

        final friendship = newState.friendships[peerA]!;
        expect(friendship.status, equals(FriendshipStatus.accepted));
        expect(friendship.isAccepted, isTrue);
        expect(friendship.updatedAt.isAfter(now) || friendship.updatedAt.isAtSameMomentAs(now), isTrue);
      });

      test('is no-op if friendship is not in received status', () {
        final now = DateTime.now();
        final existingFriendship = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          status: FriendshipStatus.pending,
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: existingFriendship},
        );

        final action = AcceptFriendRequestAction(peerA);

        final newState = friendshipsReducer(state, action);

        expect(identical(newState, state), isTrue);
      });

      test('is no-op if friendship does not exist', () {
        const state = FriendshipsState.initial;

        final action = AcceptFriendRequestAction(peerA);

        final newState = friendshipsReducer(state, action);

        expect(identical(newState, state), isTrue);
      });
    });

    group('ProcessFriendshipAcceptAction', () {
      test('changes pending to accepted when they accept our request', () {
        final now = DateTime.now();
        final existingFriendship = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          status: FriendshipStatus.pending,
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: existingFriendship},
        );

        final action = ProcessFriendshipAcceptAction(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
        );

        final newState = friendshipsReducer(state, action);

        final friendship = newState.friendships[peerA]!;
        expect(friendship.status, equals(FriendshipStatus.accepted));
        expect(friendship.isAccepted, isTrue);
      });

      test('creates new accepted friendship if it does not exist (edge case)', () {
        const state = FriendshipsState.initial;

        final action = ProcessFriendshipAcceptAction(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
        );

        final newState = friendshipsReducer(state, action);

        expect(newState.friendships.containsKey(peerA), isTrue);
        final friendship = newState.friendships[peerA]!;
        expect(friendship.status, equals(FriendshipStatus.accepted));
        expect(friendship.nickname, equals('Alice'));
      });

      test('updates nickname when processing accept', () {
        final now = DateTime.now();
        final existingFriendship = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice Old',
          status: FriendshipStatus.pending,
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: existingFriendship},
        );

        final action = ProcessFriendshipAcceptAction(
          peerPubkeyHex: peerA,
          nickname: 'Alice New',
        );

        final newState = friendshipsReducer(state, action);

        final friendship = newState.friendships[peerA]!;
        expect(friendship.nickname, equals('Alice New'));
      });
    });

    group('DeclineFriendRequestAction', () {
      test('changes status to declined for received requests', () {
        final now = DateTime.now();
        final existingFriendship = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          status: FriendshipStatus.received,
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: existingFriendship},
        );

        final action = DeclineFriendRequestAction(peerA);

        final newState = friendshipsReducer(state, action);

        final friendship = newState.friendships[peerA]!;
        expect(friendship.status, equals(FriendshipStatus.declined));
      });

      test('is no-op if friendship is not pending incoming', () {
        final now = DateTime.now();
        final existingFriendship = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          status: FriendshipStatus.pending,
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: existingFriendship},
        );

        final action = DeclineFriendRequestAction(peerA);

        final newState = friendshipsReducer(state, action);

        expect(identical(newState, state), isTrue);
      });
    });

    group('RemoveFriendshipAction', () {
      test('removes friendship entirely from map', () {
        final now = DateTime.now();
        final friendshipA = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          status: FriendshipStatus.accepted,
          createdAt: now,
          updatedAt: now,
        );
        final friendshipB = FriendshipState(
          peerPubkeyHex: peerB,
          nickname: 'Bob',
          status: FriendshipStatus.accepted,
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: friendshipA, peerB: friendshipB},
        );

        final action = RemoveFriendshipAction(peerA);

        final newState = friendshipsReducer(state, action);

        expect(newState.friendships.containsKey(peerA), isFalse);
        expect(newState.friendships.containsKey(peerB), isTrue);
        expect(newState.friendships.length, equals(1));
      });
    });

    group('HandleUnfriendedByAction', () {
      test('removes friendship entirely from map', () {
        final now = DateTime.now();
        final existingFriendship = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          status: FriendshipStatus.accepted,
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: existingFriendship},
        );

        final action = HandleUnfriendedByAction(peerA);

        final newState = friendshipsReducer(state, action);

        expect(newState.friendships.containsKey(peerA), isFalse);
        expect(newState.friendships.isEmpty, isTrue);
      });
    });

    group('HydrateFriendshipsAction', () {
      test('replaces all friendships with provided map', () {
        final now = DateTime.now();
        final oldFriendship = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          status: FriendshipStatus.accepted,
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: oldFriendship},
        );

        final newFriendship = FriendshipState(
          peerPubkeyHex: peerB,
          nickname: 'Bob',
          status: FriendshipStatus.pending,
          createdAt: now,
          updatedAt: now,
        );
        final action = HydrateFriendshipsAction({peerB: newFriendship});

        final newState = friendshipsReducer(state, action);

        expect(newState.friendships.containsKey(peerA), isFalse);
        expect(newState.friendships.containsKey(peerB), isTrue);
        expect(newState.friendships.length, equals(1));
        expect(newState.friendships[peerB]!.nickname, equals('Bob'));
      });
    });

    group('UpdateFriendshipUdpAddressAction', () {
      test('updates UDP address on existing friendship', () {
        final now = DateTime.now();
        final existingFriendship = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          status: FriendshipStatus.accepted,
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: existingFriendship},
        );

        final action = UpdateFriendshipUdpAddressAction(
          peerPubkeyHex: peerA,
          udpAddress: '[2001:db8::1]:4001',
        );

        final newState = friendshipsReducer(state, action);

        final friendship = newState.friendships[peerA]!;
        expect(friendship.udpAddress, equals('[2001:db8::1]:4001'));
        expect(friendship.updatedAt.isAfter(now) || friendship.updatedAt.isAtSameMomentAs(now), isTrue);
      });

      test('updates UDP address when provided', () {
        final now = DateTime.now();
        final existingFriendship = FriendshipState(
          peerPubkeyHex: peerA,
          nickname: 'Alice',
          status: FriendshipStatus.accepted,
          udpAddress: '[2001:db8::1]:4001',
          createdAt: now,
          updatedAt: now,
        );
        final state = FriendshipsState(
          friendships: {peerA: existingFriendship},
        );

        final action = UpdateFriendshipUdpAddressAction(
          peerPubkeyHex: peerA,
          udpAddress: '[2001:db8::2]:4001',
        );

        final newState = friendshipsReducer(state, action);

        final friendship = newState.friendships[peerA]!;
        expect(friendship.udpAddress, equals('[2001:db8::2]:4001'));
      });

      test('is no-op if friendship does not exist', () {
        const state = FriendshipsState.initial;

        final action = UpdateFriendshipUdpAddressAction(
          peerPubkeyHex: peerA,
          udpAddress: '[2001:db8::1]:4001',
        );

        final newState = friendshipsReducer(state, action);

        expect(identical(newState, state), isTrue);
        expect(newState.friendships.isEmpty, isTrue);
      });
    });

    group('unknown action', () {
      test('returns state unchanged for unrecognized action', () {
        const state = FriendshipsState.initial;
        // Create a dummy action that extends FriendshipAction
        final action = _UnknownAction();

        final newState = friendshipsReducer(state, action);

        expect(identical(newState, state), isTrue);
      });
    });
  });
}

/// A dummy action for testing the default/fallthrough case
class _UnknownAction extends FriendshipAction {}

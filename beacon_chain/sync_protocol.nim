import
  options, tables, sequtils, algorithm, sets, macros,
  chronicles, chronos, metrics, stew/ranges/bitranges,
  spec/[datatypes, crypto, digest, helpers], eth/rlp,
  beacon_node_types, eth2_network, beacon_chain_db, block_pool, time, ssz

when networkBackend == rlpxBackend:
  import eth/rlp/options as rlpOptions
  template libp2pProtocol*(name: string, version: int) {.pragma.}

declareGauge libp2p_peers, "Number of libp2p peers"

type
  ValidatorSetDeltaFlags {.pure.} = enum
    Activation = 0
    Exit = 1

  ValidatorChangeLogEntry* = object
    case kind*: ValidatorSetDeltaFlags
    of Activation:
      pubkey: ValidatorPubKey
    else:
      index: uint32

  ValidatorSet = seq[Validator]

  BeaconSyncNetworkState* = ref object
    node*: BeaconNode
    db*: BeaconChainDB

  BeaconSyncPeerState* = ref object
    initialHelloReceived: bool

  BlockRootSlot* = object
    blockRoot: Eth2Digest
    slot: Slot

const
  maxBlocksToRequest = 64'u64
  MaxAncestorBlocksResponse = 256

func toHeader(b: BeaconBlock): BeaconBlockHeader =
  BeaconBlockHeader(
    slot: b.slot,
    parent_root: b.parent_root,
    state_root: b.state_root,
    body_root: hash_tree_root(b.body),
    signature: b.signature
  )

proc fromHeaderAndBody(b: var BeaconBlock, h: BeaconBlockHeader, body: BeaconBlockBody) =
  doAssert(hash_tree_root(body) == h.body_root)
  b.slot = h.slot
  b.parent_root = h.parent_root
  b.state_root = h.state_root
  b.body = body
  b.signature = h.signature

proc importBlocks(node: BeaconNode,
                  blocks: openarray[BeaconBlock]) =
  for blk in blocks:
    node.onBeaconBlock(node, blk)
  info "Forward sync imported blocks", len = blocks.len

type
  HelloMsg = object
    forkVersion*: array[4, byte]
    finalizedRoot*: Eth2Digest
    finalizedEpoch*: Epoch
    headRoot*: Eth2Digest
    headSlot*: Slot

proc getCurrentHello(node: BeaconNode): HelloMsg =
  let
    blockPool = node.blockPool
    finalizedHead = blockPool.finalizedHead
    headBlock = blockPool.head.blck
    headRoot = headBlock.root
    headSlot = headBlock.slot
    finalizedEpoch = finalizedHead.slot.compute_epoch_of_slot()

  HelloMsg(
    fork_version: node.forkVersion,
    finalizedRoot: finalizedHead.blck.root,
    finalizedEpoch: finalizedEpoch,
    headRoot: headRoot,
    headSlot: headSlot)

proc handleInitialHello(peer: Peer,
                        node: BeaconNode,
                        ourHello: HelloMsg,
                        theirHello: HelloMsg) {.async, gcsafe.}

p2pProtocol BeaconSync(version = 1,
                       rlpxName = "bcs",
                       networkState = BeaconSyncNetworkState,
                       peerState = BeaconSyncPeerState):

  onPeerConnected do (peer: Peer):
    if peer.wasDialed:
      let
        node = peer.networkState.node
        ourHello = node.getCurrentHello
        theirHello = await peer.hello(ourHello)

      if theirHello.isSome:
        await peer.handleInitialHello(node, ourHello, theirHello.get)
      else:
        warn "Hello response not received in time"

  onPeerDisconnected do (peer: Peer):
    libp2p_peers.set peer.network.peers.len.int64

  requestResponse:
    proc hello(peer: Peer, theirHello: HelloMsg) {.libp2pProtocol("hello", 1).} =
      let
        node = peer.networkState.node
        ourHello = node.getCurrentHello

      await response.send(ourHello)

      if not peer.state.initialHelloReceived:
        peer.state.initialHelloReceived = true
        await peer.handleInitialHello(node, ourHello, theirHello)

    proc helloResp(peer: Peer, msg: HelloMsg) {.libp2pProtocol("hello", 1).}

  proc goodbye(peer: Peer, reason: DisconnectionReason) {.libp2pProtocol("goodbye", 1).}

  requestResponse:
    proc beaconBlocksByRange(
            peer: Peer,
            headBlockRoot: Eth2Digest,
            startSlot: Slot,
            count: uint64,
            step: uint64) {.
            libp2pProtocol("beacon_blocks_by_range", 1).} =

      if count > 0'u64:
        let count = if step != 0: min(count, maxBlocksToRequest.uint64) else: 1
        let pool = peer.networkState.node.blockPool
        var results: array[maxBlocksToRequest, BlockRef]
        let
          lastPos = min(count.int, results.len) - 1
          firstPos = pool.getBlockRange(headBlockRoot, startSlot, step,
                                        results.toOpenArray(0, lastPos))
        for i in firstPos.int .. lastPos.int:
          await response.write(pool.get(results[i]).data)

    proc beaconBlocksByRoot(
            peer: Peer,
            blockRoots: openarray[Eth2Digest]) {.
            libp2pProtocol("beacon_blocks_by_root", 1).} =
      let
        pool = peer.networkState.node.blockPool
        db = peer.networkState.db

      for root in blockRoots:
        let blockRef = pool.getRef(root)
        if not isNil(blockRef):
          await response.write(pool.get(blockRef).data)

    proc beaconBlocks(
            peer: Peer,
            blocks: openarray[BeaconBlock])

proc handleInitialHello(peer: Peer,
                        node: BeaconNode,
                        ourHello: HelloMsg,
                        theirHello: HelloMsg) {.async, gcsafe.} =

  if theirHello.forkVersion != node.forkVersion:
    await peer.disconnect(IrrelevantNetwork)
    return

  # TODO: onPeerConnected runs unconditionally for every connected peer, but we
  # don't need to sync with everybody. The beacon node should detect a situation
  # where it needs to sync and it should execute the sync algorithm with a certain
  # number of randomly selected peers. The algorithm itself must be extracted in a proc.
  try:
    libp2p_peers.set peer.network.peers.len.int64

    debug "Peer connected. Initiating sync", peer,
          headSlot = ourHello.headSlot,
          remoteHeadSlot = theirHello.headSlot

    let bestDiff = cmp((ourHello.finalizedEpoch, ourHello.headSlot),
                       (theirHello.finalizedEpoch, theirHello.headSlot))
    if bestDiff >= 0:
      # Nothing to do?
      debug "Nothing to sync", peer
    else:
      # TODO: Check for WEAK_SUBJECTIVITY_PERIOD difference and terminate the
      # connection if it's too big.
      var s = ourHello.headSlot + 1
      var theirHello = theirHello
      while s <= theirHello.headSlot:
        let numBlocksToRequest = min(uint64(theirHello.headSlot - s),
                                     maxBlocksToRequest)

        debug "Requesting blocks", peer, remoteHeadSlot = theirHello.headSlot,
                                         ourHeadSlot = s,
                                         numBlocksToRequest

        let blocks = await peer.beaconBlocksByRange(theirHello.headRoot, s,
                                                    numBlocksToRequest, 1'u64)
        if blocks.isSome:
          info "got blocks", total = blocks.get.len
          if blocks.get.len == 0:
            info "Got 0 blocks while syncing", peer
            break

          node.importBlocks blocks.get
          let lastSlot = blocks.get[^1].slot
          if lastSlot <= s:
            info "Slot did not advance during sync", peer
            break

          s = lastSlot + 1

          # TODO: Maybe this shouldn't happen so often.
          # The alternative could be watching up a timer here.
          let helloResp = await peer.hello(node.getCurrentHello)
          if helloResp.isSome:
            theirHello = helloResp.get
          else:
            # We'll ignore this error and we'll try to request
            # another range optimistically. If that fails, the
            # syncing will be interrupted.
            discard
        else:
          error "didn't got objectes in time"
          break

  except CatchableError:
    warn "Failed to sync with peer", peer, err = getCurrentExceptionMsg()


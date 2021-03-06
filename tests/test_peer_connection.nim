import
  unittest, os,
  chronos, confutils,
  ../beacon_chain/[conf, eth2_network]

template asyncTest*(name, body: untyped) =
  test name:
    proc scenario {.async.} = body
    waitFor scenario()

asyncTest "connect two nodes":
  let tempDir = getTempDir() / "peers_test"

  var c1 = BeaconNodeConf.defaults
  c1.dataDir = OutDir(tempDir / "node-1")
  c1.tcpPort = 50000
  c1.nat = "none"

  var n1PersistentAddress = c1.getPersistenBootstrapAddr(
    parseIpAddress("127.0.0.1"), Port c1.tcpPort)

  var n1 = await createEth2Node(c1)

  echo "Node 1 persistent address: ", n1PersistentAddress

  when networkBackend != rlpxBackend:
    var n1ActualAddress = await n1.daemon.identity()
    echo "Node 1 actual address:", n1ActualAddress

  echo "Press any key to continue"
  discard stdin.readLine()

  var c2 = BeaconNodeConf.defaults
  c2.dataDir = OutDir(tempDir / "node-2")
  c2.tcpPort = 50001
  c2.nat = "none"
  var n2 = await createEth2Node(c2)

  await n2.connectToNetwork(bootstrapNodes = @[n1PersistentAddress])


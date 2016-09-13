quark 1.0;

/* There are more tests in tests/test_*.py. */

include ../mdk-2.0.q;

package datawire_mdk_test 1.0.0;

import quark.test;
import quark.reflect;

import mdk_tracing;
import mdk_tracing.protocol;
import mdk_runtime;
import mdk_discovery;

void main(List<String> args) {
    test.run(args);
}

FakeWSActor expectSocket(MDKRuntime runtime, String url) {
    FakeWebSockets ws = ?runtime.getWebSocketsService();
    FakeWSActor actor = ws.lastConnection();
    // May or may not have token appended depending on env variables...
    if (!actor.url.startsWith(url)) {
        checkEqual(url, actor.url);
        return null;
    } else {
        return actor;
    }
}

class TracingTest {
    MDKRuntime runtime;

    TracingTest() {
        self.runtime = fakeRuntime();
        FakeEnvVars env = ?self.runtime.getEnvVarsService();
        env.set("DATAWIRE_TOKEN", "");
    }

    void pump() {
        FakeTime timeService = ?runtime.getTimeService();
        timeService.pump();
    }

    /////////////////
    // Helpers

    ProtocolEvent expectTracingEvent(FakeWSActor sev, String expectedType) {
        String msg = sev.expectTextMessage();
        if (msg == null) {
            check(false, "No message sent.");
            return null;
        }
        ProtocolEvent evt = TracingEvent.decode(msg);
        String type = evt.getClass().getName();
        if (check(type == expectedType, "expected " + expectedType + " event, got " + type)) {
            return ?evt;
        } else {
            return null;
        }
    }

    Open expectOpen(FakeWSActor evt) {
        return ?expectTracingEvent(evt, "mdk_protocol.Open");
    }

    LogEvent expectLogEvent(FakeWSActor evt) {
        return ?expectTracingEvent(evt, "mdk_tracing.protocol.LogEvent");
    }

    Subscribe expectSubscribe(FakeWSActor evt) {
        return ?expectTracingEvent(evt, "mdk_tracing.protocol.Subscribe");
    }

    /////////////////
    // Tests

    void testLog() {
        doTestLog(null);
    }

    void testLogCustomURL() {
        doTestLog("custom");
    }

    FakeWSActor startTracer(Tracer tracer) {
        tracer.initContext();
        tracer.log("procUUID", "DEBUG", "blah", "testing...");
        self.pump();
        FakeWSActor sev = expectSocket(self.runtime, tracer.url + "?token=" + tracer.token);
        if (sev == null) {
            check(false, "No FakeWSActor returned.");
            return null;
        }
        sev.accept();
        self.pump();
        Open open = expectOpen(sev);
        if (open == null) { return null; }
        self.pump();
        return sev;
    }

    void doTestLog(String url) {
        Tracer tracer = new Tracer(runtime);
        if (url != null) {
            tracer.url = url;
        } else {
            url = tracer.url;
        }
        FakeWSActor sev = startTracer(tracer);
        if (sev == null) { return; }
        LogEvent evt = expectLogEvent(sev);
        if (evt == null) { return; }
        checkEqual("DEBUG", evt.level);
        checkEqual("blah", evt.category);
        checkEqual("testing...", evt.text);
    }

    // Unexpected messages are ignored.
    void testUnexpectedMessage() {
        Tracer tracer = new Tracer(runtime);
        FakeWSActor sev = startTracer(tracer);
        if (sev == null) { return; }
        sev.send("{\"type\": \"UnknownMessage\"}");
        self.pump();
        checkEqual("CONNECTED", sev.state);
    }

    void _subhandler(LogEvent evt, List<LogEvent> events) {
        events.add(evt);
    }

    void testSubscribe() {
        Tracer tracer = new Tracer(runtime);
        List<LogEvent> events = [];
        tracer.subscribe(bind(self, "_subhandler", [events]));
        self.pump();
        FakeWSActor sev = expectSocket(self.runtime, tracer.url + "?token=" + tracer.token);
        if (sev == null) { return; }
        sev.accept();
        self.pump();
        Open open = expectOpen(sev);
        if (open == null) { return; }
        Subscribe sub = expectSubscribe(sev);
        if (sub == null) { return; }
        LogEvent e = new LogEvent();
        e.text = "asdf";
        sev.send(e.encode());
        self.pump();
        checkEqual(1, events.size());
        LogEvent evt = events[0];
        checkEqual("asdf", evt.text );
    }

}

import mdk_discovery;
import mdk_discovery.protocol;


class UnSerializable extends Serializable {
    static UnSerializable construct() {
        return null;
    }
}

class SerializableTest {
    // Unexpected messages result in a null, not in a panic
    void testUnexpected() {
        Object result = Serializable.decodeClass(Class.get("datawire_mdk_test.UnSerializable"),
                                                 "{\"type\": \"UnSerializable\"}");
        checkEqual(null, result);
    }
}

class DiscoveryTest {
    MDKRuntime runtime;
    DiscoClient client;

    void setup() {
        self.runtime = fakeRuntime();
        self.runtime.dependencies.registerService("failurepolicy_factory",
                                                  new CircuitBreakerFactory(runtime));
    }

    void pump() {
        FakeTime timeService = ?runtime.getTimeService();
        timeService.pump();
    }

    /////////////////
    // Helpers

    ProtocolEvent expectDiscoveryEvent(FakeWSActor sev, String expectedType) {
        String msg = sev.expectTextMessage();
        if (msg == null) {
            check(false, "No discovery event sent at all.");
            return null;
        }
        ProtocolEvent evt = DiscoveryEvent.decode(msg);
        String type = evt.getClass().getName();
        if (check(type == expectedType, "expected " + expectedType + " event, got " + type)) {
            return ?evt;
        } else {
            return null;
        }
    }

    Open expectOpen(FakeWSActor evt) {
        return ?expectDiscoveryEvent(evt, "mdk_protocol.Open");
    }

    Active expectActive(FakeWSActor evt) {
        return ?expectDiscoveryEvent(evt, "mdk_discovery.protocol.Active");
    }

    void checkEqualNodes(Node expected, Node actual) {
        checkEqual(expected.service, actual.service);
        checkEqual(expected.address, actual.address);
        checkEqual(expected.version, actual.version);
        checkEqual(expected.properties, actual.properties);
    }

    Discovery createDisco() {
        Discovery disco = new Discovery(runtime);
        self.client = ?new mdk_discovery.protocol.DiscoClientFactory("").create(disco, self.runtime);
        runtime.dependencies.registerService("discovery_registrar", self.client);
        return disco;
    }

    FakeWSActor startDisco(Discovery disco) {
        self.runtime.dispatcher.startActor(disco);
        self.runtime.dispatcher.startActor(self.client);
        self.pump();
        FakeWSActor sev = expectSocket(self.runtime, self.client.url());
        if (sev == null) {
            check(false, "No FakeWSActor returned.");
            return null;
        }
        sev.accept();
        sev.send(new Open().encode());
        return sev;
    }

    /////////////////
    // Tests

    void testStart() {
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);
        if (sev == null) {
            check(false, "No FakeWSActor created.");
            return;
        }
    }

    void testFailedStart() {
        // ...
    }

    void testRegisterPreStart() {
        Discovery disco = self.createDisco();

        Node node = new Node();
        node.service = "svc";
        node.address = "addr";
        node.version = "1.2.3";
        disco.register(node);

        FakeWSActor sev = startDisco(disco);
        if (sev == null) { return; }

        Open open = expectOpen(sev);
        if (open == null) { return; }

        Active active = expectActive(sev);
        if (active == null) { return; }
        checkEqualNodes(node, active.node);
    }

    void testRegisterPostStart() {
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);

        Node node = new Node();
        node.service = "svc";
        node.address = "addr";
        node.version = "1.2.3";
        disco.register(node);

        Open open = expectOpen(sev);
        if (open == null) { return; }
        Active active = expectActive(sev);
        if (active == null) { return; }
        checkEqualNodes(node, active.node);
    }

    void testRegisterTheNiceWay() {
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);

        Node node = new Node();
        node.service = "svc";
        node.address = "addr";
        node.version = "1.2.3";
        disco.register_service(node.service, node.address, node.version);

        Open open = expectOpen(sev);
        if (open == null) { return; }
        Active active = expectActive(sev);
        if (active == null) { return; }
        checkEqualNodes(node, active.node);
    }

    Node doActive(FakeWSActor sev, String svc, String addr, String version) {
        Active active = new Active();
        active.node = new Node();
        active.node.service = svc;
        active.node.address = addr;
        active.node.version = version;
        sev.send(active.encode());
        return active.node;
    }

    void testResolvePreStart() {
        Discovery disco = self.createDisco();

        Promise promise = disco._resolve("svc", "1.0");
        checkEqual(false, promise.value().hasValue());

        FakeWSActor sev = startDisco(disco);
        if (sev == null) { return; }

        Node node = doActive(sev, "svc", "addr", "1.2.3");

        checkEqualNodes(node, ?promise.value().getValue());
    }

    void testResolvePostStart() {
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);

        Promise promise = disco._resolve("svc", "1.0");
        checkEqual(false, promise.value().hasValue());

        Node node = doActive(sev, "svc", "addr", "1.2.3");

        checkEqualNodes(node, ?promise.value().getValue());
    }

    void testResolveAfterNotification() {
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);

        Node node = doActive(sev, "svc", "addr", "1.2.3");

        Promise promise = disco._resolve("svc", "1.0");
        checkEqualNodes(node, ?promise.value().getValue());
    }

    // This variant caught a bug in the code, so it's useful to have all of
    // these even though they're seemingly similar.
    void testResolveBeforeAndBeforeNotification() {
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);
        Promise promise = disco._resolve("svc", "1.0");
        Promise promise2 = disco._resolve("svc", "1.0");
        checkEqual(false, promise.value().hasValue());
        checkEqual(false, promise2.value().hasValue());

        Node node = doActive(sev, "svc", "addr", "1.2.3");

        checkEqualNodes(node, ?promise.value().getValue());
        checkEqualNodes(node, ?promise2.value().getValue());
    }

    void testResolveBeforeAndAfterNotification() {
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);
        Promise promise = disco._resolve("svc", "1.0");

        Node node = doActive(sev, "svc", "addr", "1.2.3");

        Promise promise2 = disco._resolve("svc", "1.0");
        checkEqualNodes(node, ?promise.value().getValue());
        checkEqualNodes(node, ?promise2.value().getValue());
    }

    void testResolveDifferentActive() {
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);

        Node node = doActive(sev, "svc", "addr", "1.2.3");
        doActive(sev, "svc2", "addr", "1.2.3");

        Promise promise = disco._resolve("svc", "1.0");
        checkEqualNodes(node, ?promise.value().getValue());
    }

    void testResolveVersionAfterActive() {
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);

        Node n1 = doActive(sev, "svc", "addr1.0", "1.0.0");
        Node n2 = doActive(sev, "svc", "addr1.2.3", "1.2.3");

        Promise promise = disco._resolve("svc", "1.0");
        checkEqualNodes(n1, ?promise.value().getValue());
        promise = disco._resolve("svc", "1.1");
        checkEqualNodes(n2, ?promise.value().getValue());
    }

    void testResolveVersionBeforeActive() {
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);

        Promise p1 = disco._resolve("svc", "1.0");
        Promise p2 = disco._resolve("svc", "1.1");

        Node n1 = doActive(sev, "svc", "addr1.0", "1.0.0");
        Node n2 = doActive(sev, "svc", "addr1.2.3", "1.2.3");

        checkEqualNodes(n1, ?p1.value().getValue());
        checkEqualNodes(n2, ?p2.value().getValue());
    }

    void testResolveBreaker() {
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);

        Node n1 = doActive(sev, "svc", "addr1", "1.0.0");
        Node n2 = doActive(sev, "svc", "addr2", "1.0.0");

        Promise p = disco._resolve("svc", "1.0");
        checkEqualNodes(n1, ?p.value().getValue());
        p = disco._resolve("svc", "1.0");
        checkEqualNodes(n2, ?p.value().getValue());

        Node failed = ?p.value().getValue();
        int idx = 0;
        CircuitBreakerFactory fpfactory = ?disco._fpfactory;
        while (idx < fpfactory.threshold) {
            failed.failure();
            idx = idx + 1;
        }

        p = disco._resolve("svc", "1.0");
        checkEqualNodes(n1, ?p.value().getValue());
        p = disco._resolve("svc", "1.0");
        checkEqualNodes(n1, ?p.value().getValue());
    }

    void testLoadBalancing() {
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);

        Promise promise = disco._resolve("svc", "1.0");
        checkEqual(false, promise.value().hasValue());

        Active active = new Active();

        int idx = 0;
        int count = 10;
        while (idx < count) {
            active.node = new Node();
            active.node.service = "svc";
            active.node.address = "addr" + idx.toString();
            active.node.version = "1.2.3";
            sev.send(active.encode());
            idx = idx + 1;
        }

        idx = 0;
        while (idx < count*10) {
            Node node = ?disco._resolve("svc", "1.0").value().getValue();
            checkEqual("addr" + (idx % count).toString(), node.address);
            idx = idx + 1;
        }
    }

    void testReconnect() {
        // ...
    }

    // Unexpected messages are ignored.
    void testUnexpectedMessage() {
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);
        sev.send("{\"type\": \"UnknownMessage\"}");
        self.pump();
        checkEqual("CONNECTED", sev.state);
    }

    void testStop() {
        FakeTime timeService = ?runtime.getTimeService();
        Discovery disco = self.createDisco();
        FakeWSActor sev = startDisco(disco);

        Node node = new Node();
        node.service = "svc";
        node.address = "addr";
        node.version = "1.2.3";
        disco.register(node);

        Open open = expectOpen(sev);
        if (open == null) { return; }
        Active active = expectActive(sev);
        if (active == null) { return; }

        runtime.dispatcher.stopActor(disco);
        runtime.dispatcher.stopActor(client);
        runtime.stop();
        // Might take some cleanup to stop everything:
        timeService.advance(15.0);
        self.pump();
        self.pump();
        self.pump();
        self.pump();

        // At this point we should have nothing scheduled and socket should be
        // closed:
        FakeWebSockets ws = ?runtime.getWebSocketsService();
        checkEqual([sev], ws.fakeActors); // Only the one connection
        checkEqual("DISCONNECTED", sev.state);
        checkEqual(0, timeService.scheduled());
    }

}

class UtilTest {

    void testVersionMatch() {
        checkEqual(true, versionMatch("1", "1.0.0"));
        checkEqual(true, versionMatch("1.0", "1.0.0"));
        checkEqual(true, versionMatch("1.0.0", "1.0.0"));
        checkEqual(true, versionMatch("1.0.0", "1.0"));
        checkEqual(true, versionMatch("1.0.0", "1"));

        checkEqual(true, versionMatch("1.0", "1.1"));
        checkEqual(true, versionMatch("1.0", "1.1.0"));
        checkEqual(true, versionMatch("1.1", "1.1"));
        checkEqual(true, versionMatch("1.1", "1.1.0"));

        checkEqual(false, versionMatch("1.2", "1.1.0"));
        checkEqual(false, versionMatch("2.0", "1.1.0"));
        checkEqual(false, versionMatch("1.3", "1.2"));
    }

}

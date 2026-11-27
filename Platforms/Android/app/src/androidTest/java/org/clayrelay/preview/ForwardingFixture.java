package org.clayrelay.preview;

import org.json.JSONArray;
import org.json.JSONObject;

/** Synthetic loopback forwarding profiles shared by the Relay and VPN checks. */
final class ForwardingFixture {
    static final int WORKING = 4, COUNT = 8;
    private static final int[] endpoints = {0, 1, 2, 3, 0, 1, 2, 3};
    private final String[] input;

    ForwardingFixture(String fixture) {
        if (fixture == null || !fixture.matches("(?:[0-9]{1,5},){4}(?:[a-f0-9]{24},){3}[a-f0-9]{64}"))
            throw new AssertionError("isolated loopback forwarding fixture is required");
        input = fixture.split(",");
    }

    String profile() throws Exception {
        // Four working upstreams, then invalid credentials and invalid pins for both protocols.
        String wrongPin = (input[7].startsWith("a") ? "b" : "a") + input[7].substring(1);
        JSONArray nodes = new JSONArray();
        for (int i = 0; i < endpoints.length; i++) {
            int endpoint = endpoints[i];
            JSONObject node = new JSONObject().put("type", endpoint % 2 == 0 ? "http" : "socks5")
                    .put("name", "Loopback-" + (i + 1)).put("server", "10.0.2.2").put("port", Integer.parseInt(input[endpoint]))
                    .put("username", input[5]).put("password", i == 4 || i == 5 ? "fixture-wrong-password" : input[6]);
            if (endpoint >= 2) node.put("tls", true).put("fingerprint", i >= 6 ? wrongPin : input[7]);
            nodes.put(node);
        }
        return new JSONObject().put("proxies", nodes).toString();
    }

    String label(int node) {
        int endpoint = endpoints[node - 1];
        return (endpoint % 2 == 0 ? "HTTP CONNECT" : "SOCKS5") + (endpoint >= 2 ? " / TCP / TLS" : " / TCP");
    }

    String proof(int node) { return input[4] + "-" + node; }
    boolean hasPrivateData(String status) {
        return status.contains(input[5]) || status.contains(input[6]) || status.contains("10.0.2.2");
    }
}

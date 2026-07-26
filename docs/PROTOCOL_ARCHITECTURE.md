# Sony protocol architecture

## Current status

The application transport knows Sony's V1 and V2 RFCOMM services. It opens them
in a compatibility-safe order, then `SonyProtocolSession` negotiates from the
initialization response and service hint. A four-byte canonical response selects
V1; an eight-byte response selects V2.

`SonyProtocolV1` remains the only production adapter. WH-1000XM3/XM4 behavior is
the protected baseline. V2 is detected and fails closed as unsupported, so an
XM5/XM6 cannot accidentally receive a command from the V1 opcode table. This is
transport and negotiation support, not a claim of full XM5/XM6 feature support.

## Module boundary

`SonyConnectCore` has no AppKit, IOBluetooth, CoreAudio, or logging dependency.
It owns:

- byte framing and incremental stream parsing;
- protocol-neutral user/session intents;
- typed device events;
- wire requests, including their message type;
- protocol adapters and their device-reported wire-level capability state;
- protocol negotiation and session generation;
- one in-flight request, sequence/ACK correlation, timeout, and retries;
- generation-safe delayed intents through an injected scheduler.

The application target owns:

- device discovery and RFCOMM channels;
- transport connection lifecycle;
- policy such as lazy connection and automatic power-off;
- UI state and logging.

Opcodes and protocol-specific field offsets must remain private to their
adapter. A new protocol version should not introduce V1/V2 conditionals in
`HeadphonesController`.

## Contract-test boundary

Tests exercise adapters through `SonyProtocolAdapter` inputs and outputs and the
session through its public inputs and output stream. They assert exact wire
payloads, typed events, endpoint selection, negotiation, ACK serialization,
retry/failure behavior, safe V2 rejection, and stale-timer cancellation.
Framing tests cover reserved-byte escaping, fragmented and coalesced input,
checksum rejection, resynchronization, and preservation of unknown message
types.

Hardware tests remain necessary for service discovery, timing, and firmware
differences; unit tests cannot prove physical XM3–XM6 compatibility.

## Next vertical slice: V2 adapter

1. Add captured, anonymized V2 initialization and notification fixtures from
   XM5 and XM6.
2. Implement `SonyProtocolV2` read-first: initialization, battery, capabilities,
   noise control, and equalizer decoding.
3. Model feature capabilities explicitly and expose them to the menu so
   unsupported actions are hidden or disabled.
4. Enable each matching SET command only after its query/notification layout is
   covered by fixtures and verified on hardware.
5. Keep XM6 feature flags conservative until traces or hardware confirm each
   operation.

Acceptance for a model means connect, negotiate, query, set, receive NOTIFY,
disconnect, and reconnect all pass on hardware without sending an opcode from
the wrong protocol table.

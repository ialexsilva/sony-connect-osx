# Sony protocol architecture

## Current status

The application transport still opens only Sony's V1 RFCOMM service and selects
`SonyProtocolV1`. WH-1000XM3/XM4 behavior is the protected baseline. This
refactoring makes V2 implementable; it does not claim XM5/XM6 support yet.

## Module boundary

`SonyConnectCore` has no AppKit, IOBluetooth, CoreAudio, timers, or logging
dependency. It owns:

- byte framing and incremental stream parsing;
- protocol-neutral user/session intents;
- typed device events;
- wire requests, including their message type;
- protocol adapters and their device-reported wire-level capability state.

The application target owns:

- device discovery and RFCOMM channels;
- connection lifecycle, request timing, ACKs, and sequence numbers;
- policy such as lazy connection and automatic power-off;
- UI state and logging.

Opcodes and protocol-specific field offsets must remain private to their
adapter. A new protocol version should not introduce V1/V2 conditionals in
`HeadphonesController`.

## Contract-test boundary

Tests exercise adapters only through `SonyProtocolAdapter` inputs and outputs.
They assert exact wire payloads and typed events. Framing tests cover reserved
byte escaping, fragmented and coalesced input, checksum rejection,
resynchronization, and preservation of unknown message types.

Hardware tests remain necessary for service discovery, timing, and firmware
differences; unit tests cannot prove physical XM3–XM6 compatibility.

## Next vertical slice: negotiation and V2

1. Model both service UUIDs as transport endpoints instead of a single global
   V1 UUID.
2. Add a session object that owns generation/cancellation, one in-flight
   request, ACK correlation, timeout, and retry behavior.
3. Negotiate from the initialization response and service context. A four-byte
   V1 init response and an eight-byte V2 init response are known signals; model
   names may rank candidates but must not be the sole protocol decision.
4. Implement `SonyProtocolV2` read-first: initialization, battery, capabilities,
   noise control, and equalizer decoding before enabling matching SET commands.
5. Add captured V2 packet fixtures for XM5 and XM6. Keep XM6 feature flags
   conservative until traces or hardware confirm each operation.
6. Expose feature capabilities to the menu so unsupported actions are hidden or
   disabled instead of optimistically showing a state the device never applied.

Acceptance for a model means connect, negotiate, query, set, receive NOTIFY,
disconnect, and reconnect all pass on hardware without sending an opcode from
the wrong protocol table.

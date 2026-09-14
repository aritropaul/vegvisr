/**
 * Valheim `.fwl` world-metadata parser.
 *
 * Two reasons this is worth the ~60 lines. Seed strings are routinely mistyped
 * — `1`/`l`/`I` and `0`/`O` are indistinguishable in most fonts, and "my map
 * doesn't match the game" threads reliably turn out to be exactly that. And a
 * world carries the generation ruleset it was *created* under, which is not
 * necessarily the one the game is running now; the file records it, a typed
 * seed cannot.
 *
 * Layout (little-endian throughout, no compression, no checksum):
 *
 *   int32   byte length of everything below
 *   int32   worldVersion        — save-format schema version
 *   string  name
 *   string  seedName            — the phrase a player typed
 *   int32   seed                — already hashed; no need to re-derive it
 *   int64   uid
 *   int32   worldGenVersion     — terrain ruleset, distinct from worldVersion
 *
 * Strings are length-prefixed UTF-8 where the length is .NET's 7-bit-encoded
 * integer: seven bits per byte, high bit set while more bytes follow.
 */

export interface FwlWorld {
  worldVersion: number
  name: string
  seedName: string
  seed: number
  uid: bigint
  worldGenVersion: number
}

class Reader {
  private p = 0
  constructor(private readonly v: DataView) {}

  i32() {
    const x = this.v.getInt32(this.p, true)
    this.p += 4
    return x
  }

  i64() {
    const x = this.v.getBigInt64(this.p, true)
    this.p += 8
    return x
  }

  /** .NET `BinaryWriter` 7-bit-encoded length, then that many UTF-8 bytes. */
  str() {
    let len = 0
    let shift = 0
    for (;;) {
      if (shift > 35) throw new Error('malformed string length')
      const b = this.v.getUint8(this.p++)
      len |= (b & 0x7f) << shift
      if ((b & 0x80) === 0) break
      shift += 7
    }
    const bytes = new Uint8Array(this.v.buffer, this.v.byteOffset + this.p, len)
    this.p += len
    return new TextDecoder().decode(bytes)
  }

  get remaining() {
    return this.v.byteLength - this.p
  }
}

export function parseFwl(buf: ArrayBuffer): FwlWorld {
  const r = new Reader(new DataView(buf))
  const payload = r.i32()
  if (payload <= 0 || payload > buf.byteLength) {
    throw new Error('not a .fwl file (bad length prefix)')
  }
  const worldVersion = r.i32()
  // Sanity-check before trusting the rest: known world versions are in the
  // twenties and thirties, and a wrong guess here yields garbage strings that
  // would otherwise be shown to the user as a "seed".
  if (worldVersion < 1 || worldVersion > 1000) {
    throw new Error(`unexpected world version ${worldVersion}`)
  }
  const name = r.str()
  const seedName = r.str()
  const seed = r.i32()
  const uid = r.i64()
  const worldGenVersion = r.remaining >= 4 ? r.i32() : 0
  return { worldVersion, name, seedName, seed, uid, worldGenVersion }
}

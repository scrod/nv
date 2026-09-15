# Swift Crypto

The package pins Swift Crypto 4.5.2, revision
`da9d28d69ebe3894b18376c8f2395c2f37b8448f`, from
https://github.com/apple/swift-crypto. Its Apache-2.0 license and notices, including
the vendored primitive implementations, are retained in the resolved dependency.
Swift Crypto selects CryptoKit on Apple platforms and its portable implementation
on Linux; both require execution qualification.

# Zstandard

The package embeds Zstandard 1.5.7 from https://github.com/facebook/zstd,
revision `f8745da6ff1ad1e7bab384bd1f9d742439278e99`, under the BSD license.
Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
The complete license and source provenance are in `Vendor/Zstd/LICENSE` and
`Vendor/Zstd/README.nv.md`; retain that license in binary distributions.

# SQLCipher

The local build pins SQLCipher 4.19.0 revision
`c4b275a47932888216bade83aff2bbc73df0ff85` from
https://github.com/sqlcipher/sqlcipher. Its SQLite core is public domain.

Copyright (c) 2025, ZETETIC LLC
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the ZETETIC LLC nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY ZETETIC LLC ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL ZETETIC LLC BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Recovery-key checksum

The Bech32m checksum in `RecoveryArtifactsV1.swift` and its independent Python
fixture implements BIP-173/BIP-350 by Pieter Wuille and Greg Maxwell.
Sources: https://github.com/bitcoin/bips/blob/master/bip-0173.mediawiki and
https://github.com/bitcoin/bips/blob/master/bip-0350.mediawiki.

Copyright (c) 2017, 2020 Pieter Wuille and Greg Maxwell. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
OF THE POSSIBILITY OF SUCH DAMAGE.

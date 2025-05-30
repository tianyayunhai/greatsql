#ifndef MY_AES_INCLUDED
#define MY_AES_INCLUDED

/* Copyright (c) 2000, 2022, Oracle and/or its affiliates. All rights reserved.
   Copyright (c) 2023, 2024, GreatDB Software Co., Ltd.

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License, version 2.0,
 as published by the Free Software Foundation.

 This program is also distributed with certain software (including
 but not limited to OpenSSL) that is licensed under separate terms,
 as designated in a particular file or component or in included license
 documentation.  The authors of MySQL hereby grant you an additional
 permission to link the program and your derivative works with the
 separately licensed software that they have included with MySQL.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License, version 2.0, for more details.

 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA */

/**
  @file include/my_aes.h
  Wrapper to give simple interface for MySQL to AES standard encryption.
*/

#include <openssl/ec.h>
#include <openssl/evp.h>
#include "my_inttypes.h"
#include "my_macros.h"

#include <string>
#include <vector>

/** des3 */
#define MY_DES_IV_SIZE 8

/** AES IV size is 16 bytes for all supported ciphers except ECB */
#define MY_AES_IV_SIZE 16

/** AES block size is fixed to be 128 bits for CBC and ECB */
#define MY_AES_BLOCK_SIZE 16
#define SM3_DIGEST_LENGTH 32

/** Supported AES cipher/block mode combos */
enum my_aes_opmode {
  my_aes_128_ecb,
  my_aes_192_ecb,
  my_aes_256_ecb,
  my_aes_128_cbc,
  my_aes_192_cbc,
  my_aes_256_cbc,
  my_aes_128_cfb1,
  my_aes_192_cfb1,
  my_aes_256_cfb1,
  my_aes_128_cfb8,
  my_aes_192_cfb8,
  my_aes_256_cfb8,
  my_aes_128_cfb128,
  my_aes_192_cfb128,
  my_aes_256_cfb128,
  my_aes_128_ofb,
  my_aes_192_ofb,
#ifdef SSL_GM
  my_aes_256_ofb,
  my_des_ede3_cbc,
  my_sm4_ecb,
  my_sm4_cbc,
  my_sm4_cfb,
  my_sm4_ofb
#else
  my_aes_256_ofb,
  my_des_ede3_cbc
#endif
};

#define MY_AES_BEGIN my_aes_128_ecb

#ifdef SSL_GM
#define MY_AES_END my_sm4_ofb
#define MY_DEFAULT_CBC_128_MODE my_sm4_cbc
#define MY_DEFAULT_ECB_128_MODE my_sm4_ecb
#define MY_DEFAULT_CBC_256_MODE my_sm4_cbc
#define MY_DEFAULT_ECB_256_MODE my_sm4_ecb
#else
#define MY_AES_END my_des_ede3_cbc
#define MY_DEFAULT_CBC_128_MODE my_aes_128_cbc
#define MY_DEFAULT_ECB_128_MODE my_aes_128_ecb
#define MY_DEFAULT_CBC_256_MODE my_aes_256_cbc
#define MY_DEFAULT_ECB_256_MODE my_aes_256_ecb
#endif

/* If bad data discovered during decoding */
#define MY_AES_BAD_DATA -1

/** String representations of the supported AES modes. Keep in sync with
 * my_aes_opmode */
extern const char *my_aes_opmode_names[];

/**
  Encrypt a buffer using AES

  @param [in] source           Pointer to data for encryption
  @param [in] source_length    Size of encryption data
  @param [out] dest            Buffer to place encrypted data (must be large
  enough)
  @param [in] key              Key to be used for encryption
  @param [in] key_length       Length of the key. Will handle keys of any length
  @param [in] mode             encryption mode
  @param [in] iv               16 bytes initialization vector if needed.
  Otherwise NULL
  @param [in] padding          if padding needed.
  @param kdf_options           KDF options
  @return              size of encrypted data, or negative in case of error
*/

int my_aes_encrypt(const unsigned char *source, uint32 source_length,
                   unsigned char *dest, const unsigned char *key,
                   uint32 key_length, enum my_aes_opmode mode,
                   const unsigned char *iv, bool padding = true,
                   std::vector<std::string> *kdf_options = nullptr);

/**
  Encrypt Decrypt a buffer using des3

  @param [in] source           Pointer to data for encryption
  @param [in] source_length    Size of encryption data
  @param [out] dest            Buffer to place encrypted data (must be large
  enough)
  @param [in] key              Key to be used for encryption
  @param [in] key_length       Length of the key. Will handle keys of any length
  @param [in] mode             encryption mode
  @param [in] iv               16 bytes initialization vector if needed.
  Otherwise NULL
  @param [in] padding          if padding needed.
  @param kdf_options           KDF options
  @return              size of encrypted data, or negative in case of error
*/

int my_des_encrypt_decrypt(const unsigned char *source, uint32 source_length,
                           unsigned char *dest, const unsigned char *key,
                           uint32 key_length, enum my_aes_opmode mode,
                           const unsigned char *iv, int encrypt_decrypt,
                           bool padding = false,
                           std::vector<std::string> *kdf_options = nullptr);
/**
  Decrypt an AES encrypted buffer

  @param source         Pointer to data for decryption
  @param source_length  size of encrypted data
  @param dest           buffer to place decrypted data (must be large enough)
  @param key            Key to be used for decryption
  @param key_length     Length of the key. Will handle keys of any length
  @param mode           encryption mode
  @param iv             16 bytes initialization vector if needed. Otherwise NULL
  @param padding        if padding needed.
  @param kdf_options    KDF options
  @return size of original data.
*/

int my_aes_decrypt(const unsigned char *source, uint32 source_length,
                   unsigned char *dest, const unsigned char *key,
                   uint32 key_length, enum my_aes_opmode mode,
                   const unsigned char *iv, bool padding = true,
                   std::vector<std::string> *kdf_options = nullptr);

/**
  Calculate the size of a buffer large enough for encrypted data.

  @param source_length  length of data to be encrypted
  @param opmode         encryption mode
  @return               size of buffer required to store encrypted data
*/

longlong my_aes_get_size(uint32 source_length, enum my_aes_opmode opmode);

/**
  Return true if the AES cipher and block mode requires an IV.

  @param opmode           encryption mode

  @retval true   IV needed
  @retval false  IV not needed
*/

bool my_aes_needs_iv(my_aes_opmode opmode);

/**
  Encrypt a buffer using AES CBC with no padding

  @param [in] source         Pointer to data for encryption
  @param [in] source_length  Size of original data
  @param [out] dest          Buffer to place encrypted data (must be large
  enough)
  @param [in] key            Key to be used for encryption
  @param [in] key_length     Size of the key
  @param [in] iv             16-bytes initialization vector.
  @return size of encrypted data, or MY_AES_BAD_DATA in case of an error
*/

int my_legacy_aes_cbc_nopad_encrypt(const unsigned char *source,
                                    uint32 source_length, unsigned char *dest,
                                    const unsigned char *key, uint32 key_length,
                                    const unsigned char *iv);

/**
  Decrypt a buffer encrypted with AES CBC with no padding

  @param [in] source         Pointer to data for decryption
  @param [in] source_length  size of encrypted data
  @param [out] dest          buffer to place decrypted data (must be large
  enough)
  @param [in] key            Key to be used for decryption
  @param [in] key_length     Size of the key
  @param [in] iv             16-bytes initialization vector
  @return size of original data, or MY_AES_BAD_DATA in case of an error
*/

int my_legacy_aes_cbc_nopad_decrypt(const unsigned char *source,
                                    uint32 source_length, unsigned char *dest,
                                    const unsigned char *key, uint32 key_length,
                                    const unsigned char *iv);

#ifdef SSL_GM
int sm3(const unsigned char *msg, uint32 msg_length, unsigned char *dest);
int hmac_sm3(const unsigned char *source, uint32 source_length,
             unsigned char *dest, const unsigned char *key, uint32 key_length);
int sm2_encrypt(const unsigned char *source, uint32 source_length,
                unsigned char *dest, size_t &dest_len, EVP_PKEY *sm2_pkey);
int sm2_decrypt(const unsigned char *source, uint32 source_length,
                unsigned char *dest, size_t &dest_len, EVP_PKEY *sm2_pkey);
#endif /* SSL_GM */

/**
  Return true is des

  @param opmode           encryption mode

  @retval true   is ses
  @retval false  no des
*/
bool my_des_is(my_aes_opmode opmode);

#endif /* MY_AES_INCLUDED */

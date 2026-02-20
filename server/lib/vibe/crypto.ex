defmodule Vibe.Crypto do
  @moduledoc """
  Crypto helpers for Vibe. Handles key pairs and encryption.
  """

  # SECURITY: PBKDF2 iteration count - OWASP 2023 recommends 600,000+
  @pbkdf2_iterations 600_000

  @doc """
  Generates a 2048-bit RSA keypair.
  Returns {public_key_pem, private_key_pem}.

  WARNING: This should only be used for legacy v1 clients.
  For E2E security, keys should be generated on the client.
  """
  def generate_rsa_keypair do
    # Generate RSA Key
    # public_exponent = 65537 (default in openssl)
    private_key_entry = :public_key.generate_key({:rsa, 2048, 65537})

    # Extract public part
    public_key_entry = extract_public_key(private_key_entry)

    # Convert to PEM
    private_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key_entry)])
    public_pem  = :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key_entry)])

    {public_pem, private_pem}
  end

  defp extract_public_key(private_key) do
    # Erlang record for RSAPrivateKey has 11 elements including optional otherPrimeInfos
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = private_key
    {:RSAPublicKey, n, e}
  end

  @doc """
  Derives a key using PBKDF2-HMAC-SHA256.
  SECURITY: Uses 600,000 iterations per OWASP 2023 recommendations.

  Must match client-side iteration count for compatibility.
  """
  def derive_key(passphrase, salt) do
    :crypto.pbkdf2_hmac(:sha256, passphrase, salt, @pbkdf2_iterations, 32)
  end

  @doc """
  Legacy key derivation with old iteration count.
  Used only for backward compatibility with existing users.
  """
  def derive_key_legacy(passphrase, salt, iterations \\ 100000) do
    :crypto.pbkdf2_hmac(:sha256, passphrase, salt, iterations, 32)
  end

  @doc """
  Encrypts private key using AES-256-GCM.
  Returns base64(iv + ciphertext + tag) matching client format.
  """
  def encrypt_private_key(private_key_pem, derived_key) do
    iv = :crypto.strong_rand_bytes(12)

    # AES-256-GCM
    {ciphertext, tag} = :crypto.crypto_one_time_aead(
      :aes_256_gcm,
      derived_key,
      iv,
      private_key_pem,
      "", # No AAD
      16, # Tag length
      true # Encrypt
    )

    # Format: base64(iv + ciphertext + tag)
    combined = iv <> ciphertext <> tag
    Base.encode64(combined)
  end

  @doc """
  Decrypts private key encrypted with AES-256-GCM.
  Input is base64(iv + ciphertext + tag).
  """
  def decrypt_private_key(encrypted_base64, derived_key) do
    combined = Base.decode64!(encrypted_base64)

    iv = binary_part(combined, 0, 12)
    tag = binary_part(combined, byte_size(combined) - 16, 16)
    ciphertext = binary_part(combined, 12, byte_size(combined) - 12 - 16)

    case :crypto.crypto_one_time_aead(
      :aes_256_gcm,
      derived_key,
      iv,
      ciphertext,
      "", # No AAD
      tag,
      false # Decrypt
    ) do
      :error -> {:error, :decryption_failed}
      plaintext -> {:ok, plaintext}
    end
  end
end

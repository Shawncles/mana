defmodule Blockchain.Account.Storage do
  @moduledoc """
  Represents the account storage,
  as defined in Section 4.1 of the Yellow Paper.
  """

  alias ExthCrypto.Hash.Keccak
  alias MerklePatriciaTree.{Trie, DB}

  @spec put(DB.db(), EVM.trie_root(), integer(), integer()) :: Trie.t()
  def put(db, root, key, value) do
    k = encode_key(key)
    v = encode_value(value)

    db
    |> Trie.new(root)
    |> Trie.update(k, v)
  end

  @spec remove(DB.db(), EVM.trie_root(), integer()) :: Trie.t()
  def remove(db, root, key) do
    k = encode_key(key)

    db
    |> Trie.new(root)
    |> Trie.remove(k)
  end

  @spec fetch(DB.db(), EVM.trie_root(), integer()) :: integer() | nil
  def fetch(db, root, key) do
    k = encode_key(key)

    result =
      db
      |> Trie.new(root)
      |> Trie.get(k)

    if is_nil(result), do: nil, else: ExRLP.decode(result)
  end

  @spec encode_key(integer()) :: Trie.key()
  def encode_key(key) do
    key
    |> BitHelper.encode_unsigned()
    |> BitHelper.pad(32)
    |> Keccak.kec()
  end

  @spec encode_value(any()) :: binary() | nil
  def encode_value(nil), do: nil
  def encode_value(value), do: ExRLP.encode(value)

  def dump(db, root) do
    db
    |> Trie.new(root)
    |> Trie.Inspector.all_values()
    |> Enum.map(fn {k, v} ->
      {BitHelper.decode_unsigned(k), BitHelper.decode_unsigned(v)}
    end)
    |> Enum.into(%{})
  end
end

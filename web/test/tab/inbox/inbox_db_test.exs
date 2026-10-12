defmodule Tab.Inbox.InboxDBTest do
  @moduledoc """
  Row-level security for phase 4's tables (docs/specification.md, "Row-level
  security for the new tables"), in raw SQL through `Repo.as_user/2`: the
  owner, someone in the same group, and a stranger, for every verb.
  """
  use Tab.DataCase, async: true

  import Tab.LedgerSQL

  setup do
    owner = person()
    housemate = person()
    stranger = person()
    group = create_group!(owner)
    join!(housemate, group, owner)
    _ = create_group!(stranger, "Elsewhere")

    doc = document!(owner)
    item = item!(owner, doc)
    shared = expense!(owner, group, 6_000, [{owner, 3_000}, {housemate, 3_000}])
    private = expense!(housemate, group, 900, [{housemate, 900}], visibility: "private")

    %{
      owner: owner,
      housemate: housemate,
      stranger: stranger,
      group: group,
      doc: doc,
      item: item,
      shared: shared,
      private: private
    }
  end

  defp document!(uid, data \\ "%PDF-1.4 a bill") do
    id = new_id()

    run!(
      uid,
      "INSERT INTO documents (id, kind, content_type, byte_size, sha256, content) VALUES ($1, 'pdf', 'application/pdf', $2, $3, $4)",
      [id, byte_size(data), {:bytes, :crypto.hash(:sha256, data)}, {:bytes, data}]
    )

    id
  end

  defp item!(uid, doc) do
    id = new_id()

    run!(uid, "INSERT INTO pending_items (id, document_id, source) VALUES ($1, $2, 'upload')", [
      id,
      doc
    ])

    id
  end

  defp refused?({:error, %Postgrex.Error{postgres: %{code: code}}}),
    do: code in [:insufficient_privilege, :check_violation]

  defp refused?(_), do: false

  defp count(uid, table), do: run!(uid, "SELECT count(*) FROM #{table}") |> hd() |> hd()

  describe "forwarding_addresses" do
    test "only the owner sees and makes theirs; a revoked one stays revoked", ctx do
      id = new_id()

      run!(
        ctx.owner,
        "INSERT INTO forwarding_addresses (id, local_part) VALUES ($1, 'abcdefghijklmnopqrstuvwx')",
        [id]
      )

      assert count(ctx.owner, "forwarding_addresses") == 1
      assert count(ctx.housemate, "forwarding_addresses") == 0
      assert count(ctx.stranger, "forwarding_addresses") == 0

      [[stamped]] = owner!("SELECT user_id::text FROM forwarding_addresses WHERE id = $1", [id])
      assert stamped == ctx.owner

      # Making one "for" someone else makes it yours: the database stamps the maker.
      theirs = new_id()

      run!(
        ctx.stranger,
        "INSERT INTO forwarding_addresses (id, user_id, local_part) VALUES ($1, $2, 'bbcdefghijklmnopqrstuvwx')",
        [theirs, ctx.owner]
      )

      assert [[ctx.stranger]] ==
               owner!("SELECT user_id::text FROM forwarding_addresses WHERE id = $1", [theirs])

      # The secret part never changes.

      assert refused?(
               run(
                 ctx.owner,
                 "UPDATE forwarding_addresses SET local_part = 'zzcdefghijklmnopqrstuvwx'"
               )
             )

      assert {:ok, %{num_rows: 0}} =
               run(
                 ctx.stranger,
                 "UPDATE forwarding_addresses SET revoked_at = now() WHERE id = $1",
                 [id]
               )

      run!(ctx.owner, "UPDATE forwarding_addresses SET revoked_at = now()")
      assert {:error, _} = run(ctx.owner, "UPDATE forwarding_addresses SET revoked_at = NULL")
    end
  end

  describe "inbound_messages" do
    test "the person it was for reads it; nobody writes it", ctx do
      owner!(
        "INSERT INTO inbound_messages (id, provider, provider_id, user_id) VALUES ($1, 'resend', 'e1', $2)",
        [new_id(), ctx.owner]
      )

      owner!(
        "INSERT INTO inbound_messages (id, provider, provider_id) VALUES ($1, 'resend', 'e2')",
        [new_id()]
      )

      assert count(ctx.owner, "inbound_messages") == 1
      assert count(ctx.housemate, "inbound_messages") == 0

      assert refused?(
               run(
                 ctx.owner,
                 "INSERT INTO inbound_messages (provider, provider_id) VALUES ('resend', 'e3')"
               )
             )

      assert refused?(run(ctx.owner, "UPDATE inbound_messages SET status = 'stored'"))
    end
  end

  describe "documents" do
    test "the owner sees their own; nobody else does", ctx do
      assert count(ctx.owner, "documents") == 1
      assert count(ctx.housemate, "documents") == 0
      assert count(ctx.stranger, "documents") == 0
      assert {:ok, %{num_rows: 0}} = run(ctx.housemate, "UPDATE documents SET content = NULL")
    end

    test "a kept document is readable by the expense's group, and nobody else", ctx do
      run!(ctx.owner, "UPDATE documents SET expense_id = $1 WHERE id = $2", [ctx.shared, ctx.doc])

      assert count(ctx.housemate, "documents") == 1
      assert count(ctx.stranger, "documents") == 0
      # Seeing it isn't owning it.
      assert {:ok, %{num_rows: 0}} = run(ctx.housemate, "UPDATE documents SET content = NULL")
      # Kept stays kept.
      assert {:error, _} =
               run(ctx.owner, "UPDATE documents SET expense_id = NULL WHERE id = $1", [ctx.doc])
    end

    test "it can't join an expense its owner can't see", ctx do
      assert {:error, _} =
               run(ctx.owner, "UPDATE documents SET expense_id = $1 WHERE id = $2", [
                 ctx.private,
                 ctx.doc
               ])
    end

    test "purging removes the content for good and stamps it", ctx do
      run!(ctx.owner, "UPDATE documents SET content = NULL WHERE id = $1", [ctx.doc])

      [[nil, purged]] =
        owner!("SELECT content, purged_at FROM documents WHERE id = $1", [ctx.doc])

      assert purged

      assert {:error, _} =
               run(
                 ctx.owner,
                 "UPDATE documents SET content = $1, purged_at = NULL WHERE id = $2",
                 [{:bytes, "x"}, ctx.doc]
               )

      assert {:error, _} =
               run(ctx.owner, "UPDATE documents SET purged_at = NULL WHERE id = $1", [ctx.doc])
    end

    test "nobody can file a document under someone else: it's stamped as theirs", ctx do
      id = new_id()

      run!(
        ctx.stranger,
        "INSERT INTO documents (id, user_id, kind, content_type, byte_size, sha256, content) VALUES ($1, $2, 'pdf', 'application/pdf', 1, $3, 'x')",
        [id, ctx.owner, {:bytes, :crypto.hash(:sha256, "x")}]
      )

      assert [[ctx.stranger]] == owner!("SELECT user_id::text FROM documents WHERE id = $1", [id])
      assert count(ctx.owner, "documents") == 1
    end
  end

  describe "pending_items" do
    test "only the owner sees and changes them", ctx do
      assert count(ctx.owner, "pending_items") == 1
      assert count(ctx.housemate, "pending_items") == 0
      assert count(ctx.stranger, "pending_items") == 0

      assert {:ok, %{num_rows: 0}} =
               run(ctx.stranger, "UPDATE pending_items SET status = 'dismissed'")

      assert {:ok, %{num_rows: 1}} =
               run(ctx.owner, "UPDATE pending_items SET status = 'dismissed'")
    end

    test "an item can't point at someone else's document", ctx do
      theirs = document!(ctx.stranger, "%PDF-1.4 theirs")

      assert refused?(
               run(
                 ctx.owner,
                 "INSERT INTO pending_items (document_id, source) VALUES ($1, 'upload')",
                 [theirs]
               )
             )
    end

    test "an item suggests only a group its owner is in", ctx do
      elsewhere = create_group!(ctx.stranger, "Not yours")
      assert refused?(run(ctx.owner, "UPDATE pending_items SET group_id = $1", [elsewhere]))

      assert {:ok, %{num_rows: 1}} =
               run(ctx.owner, "UPDATE pending_items SET group_id = $1", [ctx.group])
    end

    test "an item confirms only into an expense its owner can see", ctx do
      assert refused?(
               run(ctx.owner, "UPDATE pending_items SET status = 'confirmed', expense_id = $1", [
                 ctx.private
               ])
             )

      assert {:ok, %{num_rows: 1}} =
               run(ctx.owner, "UPDATE pending_items SET status = 'confirmed', expense_id = $1", [
                 ctx.shared
               ])
    end
  end

  describe "the new columns" do
    test "people set their own digest days, within 1 to 28", ctx do
      assert {:ok, %{num_rows: 1}} =
               run(ctx.owner, "UPDATE profiles SET digest_days = '{1,15}' WHERE user_id = $1", [
                 ctx.owner
               ])

      assert {:error, _} =
               run(ctx.owner, "UPDATE profiles SET digest_days = '{31}' WHERE user_id = $1", [
                 ctx.owner
               ])

      assert {:ok, %{num_rows: 0}} =
               run(ctx.stranger, "UPDATE profiles SET digest_days = '{1}' WHERE user_id = $1", [
                 ctx.owner
               ])
    end
  end
end

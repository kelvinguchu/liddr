defmodule Liddr.Location.S2Hilbert do
  @moduledoc false

  import Bitwise

  @lookup_bits 4
  @swap_mask 0x01
  @invert_mask 0x02
  @max_level 30
  @pos_bits 2 * @max_level + 1
  @lookup_pos_key {__MODULE__, :lookup_pos}
  @pos_to_ij {
    {0, 1, 3, 2},
    {0, 2, 3, 1},
    {3, 2, 0, 1},
    {3, 1, 0, 2}
  }
  @pos_to_orientation {@swap_mask, 0, 0, @invert_mask + @swap_mask}

  def cell_id(face, i, j, level)
      when face in 0..5 and is_integer(i) and is_integer(j) and is_integer(level) do
    leaf_id = from_face_ij(face, i, j)
    parent_cell_id(leaf_id, level)
  end

  def token(cell_id) when is_integer(cell_id) and cell_id > 0 do
    cell_id
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.trim_trailing("0")
  end

  def token(0), do: "X"
  def token(_cell_id), do: nil

  defp from_face_ij(face, i, j) do
    n = face <<< (@pos_bits - 1)
    bits = band(face, @swap_mask)
    lookup_pos = lookup_pos()

    {n, _bits} =
      Enum.reduce(7..0//-1, {n, bits}, fn k, {acc_n, acc_bits} ->
        mask = (1 <<< @lookup_bits) - 1
        next_bits = acc_bits + ((i >>> (k * @lookup_bits) &&& mask) <<< (@lookup_bits + 2))
        next_bits = next_bits + ((j >>> (k * @lookup_bits) &&& mask) <<< 2)
        lookup = elem(lookup_pos, next_bits)
        updated_n = acc_n ||| (lookup >>> 2) <<< (k * 2 * @lookup_bits)
        {updated_n, band(lookup, @swap_mask + @invert_mask)}
      end)

    n * 2 + 1
  end

  defp lookup_pos do
    case :persistent_term.get(@lookup_pos_key, nil) do
      nil ->
        {lookup_pos, _lookup_ij} = build_lookup_tables()
        :persistent_term.put(@lookup_pos_key, lookup_pos)
        lookup_pos

      lookup_pos ->
        lookup_pos
    end
  end

  defp parent_cell_id(cell_id, level) when level in 0..@max_level do
    lsb = 1 <<< (2 * (@max_level - level))
    block = lsb <<< 1
    div(cell_id, block) * block + lsb
  end

  defp build_lookup_tables do
    pos = :array.new(1 <<< (2 * @lookup_bits + 2), default: 0)
    ij = :array.new(1 <<< (2 * @lookup_bits + 2), default: 0)

    {pos, ij} =
      Enum.reduce(0..3, {pos, ij}, fn orientation, {acc_pos, acc_ij} ->
        init_lookup_cell(0, 0, 0, orientation, 0, orientation, {acc_pos, acc_ij})
      end)

    {
      pos |> :array.to_list() |> List.to_tuple(),
      ij |> :array.to_list() |> List.to_tuple()
    }
  end

  defp init_lookup_cell(level, i, j, orig_orientation, pos, orientation, {lookup_pos, lookup_ij}) do
    if level == @lookup_bits do
      ij = (i <<< @lookup_bits) + j

      {
        :array.set((ij <<< 2) + orig_orientation, (pos <<< 2) + orientation, lookup_pos),
        :array.set((pos <<< 2) + orig_orientation, (ij <<< 2) + orientation, lookup_ij)
      }
    else
      next_level = level + 1
      next_i = i <<< 1
      next_j = j <<< 1
      next_pos = pos <<< 2
      order = elem(@pos_to_ij, orientation)

      Enum.reduce(0..3, {lookup_pos, lookup_ij}, fn step, acc ->
        ij_index = elem(order, step)
        i_delta = ij_index >>> 1
        j_delta = band(ij_index, 1)

        init_lookup_cell(
          next_level,
          next_i + i_delta,
          next_j + j_delta,
          orig_orientation,
          next_pos + step,
          bxor(orientation, elem(@pos_to_orientation, step)),
          acc
        )
      end)
    end
  end
end

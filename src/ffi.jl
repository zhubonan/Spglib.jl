using Compat: isnothing
using CoordinateTransformations
using UnPack: @unpack
using Setfield: @set
using spglib_jll: libsymspg

export get_symmetry,
    get_dataset,
    get_spacegroup_type,
    get_international,
    get_schoenflies,
    standardize_cell,
    find_primitive,
    refine_cell,
    niggli_reduce,
    delaunay_reduce,
    get_multiplicity,
    get_ir_reciprocal_mesh,
    get_stabilized_reciprocal_mesh

# This is an internal function, do not export!
function get_ccell(cell::Cell{<:AbstractMatrix,<:AbstractMatrix})
    @unpack lattice, positions, types, magmoms = cell
    # Reference: https://github.com/mdavezac/spglib.jl/blob/master/src/spglib.jl#L32-L35 and https://github.com/spglib/spglib/blob/444e061/python/spglib/spglib.py#L953-L975
    clattice = convert(Matrix{Cdouble}, lattice)
    cpositions = convert(Matrix{Cdouble}, positions)
    ctypes = Cint[findfirst(isequal(u), unique(types)) for u in types]
    if magmoms !== nothing
        magmoms = convert(Vector{Cdouble}, magmoms)
    end
    return Cell(clattice, cpositions, ctypes, magmoms)
end

# This is an internal function, do not export!
trunc_trailing_zeros(vec) = Iterators.filter(!iszero, vec)

# Reference: https://github.com/mdavezac/spglib.jl/blob/master/src/spglib.jl#L70
# This is an internal function, do not export!
cchars2string(vec) = String(collect(trunc_trailing_zeros(vec)))

convert_field(x) = x  # Integers
convert_field(x::NTuple{N,UInt8}) where {N} = String(collect(trunc_trailing_zeros(x)))
convert_field(x::Ptr) = unsafe_load(x)
convert_field(x::NTuple{M,NTuple{N,Number}}) where {M,N} =
    transpose(reshape(collect(Iterators.flatten(x)), N, M))
convert_field(x::NTuple{N,Number}) where {N} = collect(x)

function get_symmetry(cell::Cell, symprec = 1e-8)
    @unpack lattice, positions, numbers = get_ccell(cell)
    maxsize = 52 * length(positions)
    rotations = Array{Cint}(undef, maxsize, 3, 3)
    translations = Array{Cdouble}(undef, maxsize, 3)
    numops = ccall(
        (:spg_get_symmetry, libsymspg),
        Cint,
        (
            Ptr{Cint},
            Ptr{Cdouble},
            Cint,
            Ptr{Cdouble},
            Ptr{Cdouble},
            Ptr{Cint},
            Cint,
            Cdouble,
        ),
        rotations,
        translations,
        maxsize,
        lattice,
        positions,
        numbers,
        length(numbers),
        symprec,
    )
    numops == 0 && error("Could not determine symmetries!")
    [AffineMap(transpose(rotations[:, :, i]), translations[:, i]) for i in 1:numops]
end

function get_dataset(cell::Cell; symprec = 1e-8)
    @unpack lattice, positions, numbers = get_ccell(cell)
    ptr = ccall(
        (:spg_get_dataset, libsymspg),
        Ptr{SpglibDataset},
        (Ptr{NTuple{3,Cdouble}}, Ptr{NTuple{3,Cdouble}}, Ptr{Cint}, Cint, Cdouble),
        lattice,
        positions,
        numbers,
        length(numbers),
        symprec,
    )
    return convert(Dataset, unsafe_load(ptr))
end

function get_spacegroup_type(hall_number::Integer)
    spgtype = ccall(
        (:spg_get_spacegroup_type, libsymspg),
        SpglibSpacegroupType,
        (Cint,),
        hall_number,
    )
    return convert(SpaceGroup, spgtype)
end

function get_international(cell::Cell, symprec = 1e-8)
    result = zeros(Cchar, 11)
    @unpack lattice, positions, numbers = get_ccell(cell)
    exitcode = ccall(
        (:spg_get_international, libsymspg),
        Cint,
        (Ptr{Cchar}, Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cint}, Cint, Cdouble),
        result,
        lattice,
        positions,
        numbers,
        length(numbers),
        symprec,
    )
    exitcode == 0 && error("Could not determine the international symbol!")
    return cchars2string(result)
end

function get_schoenflies(cell::Cell, symprec = 1e-8)
    result = zeros(Cchar, 11)
    @unpack lattice, positions, numbers = get_ccell(cell)
    exitcode = ccall(
        (:spg_get_schoenflies, libsymspg),
        Cint,
        (Ptr{Cchar}, Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cint}, Cint, Cdouble),
        result,
        lattice,
        positions,
        numbers,
        length(numbers),
        symprec,
    )
    exitcode == 0 && error("Could not determine the Schoenflies symbol!")
    return cchars2string(result)
end

function standardize_cell(
    cell::Cell;
    to_primitive = false,
    no_idealize = false,
    symprec = 1e-5,
)
    @unpack lattice, positions, numbers = get_ccell(cell)
    exitcode = ccall(
        (:spg_standardize_cell, libsymspg),
        Cint,
        (Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cint}, Cint, Cint, Cint, Cdouble),
        lattice,
        position,
        numbers,
        length(numbers),
        to_primitive,
        no_idealize,
        symprec,
    )
    exitcode == 0 && error("Standardizing cell failed!")
    return Cell(lattice, positions, numbers)  # They have been changed now.
end

find_primitive(cell::Cell, symprec = 1e-5) =
    standardize_cell(cell; to_primitive = true, no_idealize = false, symprec = symprec)

refine_cell(cell::Cell, symprec = 1e-5) =
    standardize_cell(cell; to_primitive = false, no_idealize = false, symprec = symprec)

function niggli_reduce(cell::Cell, symprec = 1e-5)
    # Equivalent to `np.transpose` in https://github.com/atztogo/spglib/blob/f8ddf5b/python/spglib/spglib.py#L869
    lattice = Iterators.partition(getfield(cell, :lattice), 3) |> collect
    # The result is reassigned to `lattice`.
    exitcode = ccall(
        (:spg_niggli_reduce, libsymspg),
        Cint,
        (Ptr{Cdouble}, Cdouble),
        lattice,
        symprec,
    )
    iszero(exitcode) && error("Niggli reduce failed!")
    # Equivalent to `np.transpose` in https://github.com/atztogo/spglib/blob/f8ddf5b/python/spglib/spglib.py#L876
    return @set cell.lattice =
        Iterators.flatten(lattice) |> collect |> x -> reshape(x, 3, 3)
end

function delaunay_reduce(cell::Cell, symprec = 1e-5)
    # Equivalent to `np.transpose` in https://github.com/atztogo/spglib/blob/f8ddf5b/python/spglib/spglib.py#L832
    lattice = Iterators.partition(getfield(cell, :lattice), 3) |> collect
    # The result is reassigned to `lattice`.
    exitcode = ccall(
        (:spg_delaunay_reduce, libsymspg),
        Cint,
        (Ptr{Cdouble}, Cdouble),
        lattice,
        symprec,
    )
    iszero(exitcode) && error("Delaunay reduce failed!")
    # Equivalent to `np.transpose` in https://github.com/atztogo/spglib/blob/f8ddf5b/python/spglib/spglib.py#L840
    return @set cell.lattice =
        Iterators.flatten(lattice) |> collect |> x -> reshape(x, 3, 3)
end

# Doc from https://github.com/spglib/spglib/blob/d1cb3bd/src/spglib.h#L424-L439
"""
    get_ir_reciprocal_mesh(cell::Cell, mesh, is_shift = falses(3); is_time_reversal = true, symprec = 1e-5)

Return k-points mesh and k-point map to the irreducible k-points.

Irreducible reciprocal grid points are searched from uniform
mesh grid points specified by `mesh` and `is_shift`.
`mesh` stores three integers. Reciprocal primitive vectors
are divided by the number stored in `mesh` with (0,0,0) point
centering. The centering can be shifted only half of one mesh
by setting `1` or `true` for each `is_shift` element. If `0` or `false` is set for
`is_shift`, it means there is no shift. This limitation of
shifting enables the irreducible k-point search significantly
faster when the mesh is very dense.

The reducible uniform grid points are returned in reduced
coordinates as `grid_address`. A map between reducible and
irreducible points are returned as `grid_mapping_table` as in the indices of
`grid_address`. The number of the irreducible k-points are
returned as the return value.  The time reversal symmetry is
imposed by setting `is_time_reversal`.
"""
function get_ir_reciprocal_mesh(
    cell::Cell,
    mesh,
    is_shift = falses(3);
    is_time_reversal = true,
    symprec = 1e-5,
)
    # Reference: https://github.com/unkcpz/LibSymspg.jl/blob/e912dd3/src/ir-mesh-api.jl#L1-L32
    @assert length(mesh) == length(is_shift) == 3
    @assert all(isone(x) || iszero(x) for x in is_shift)
    # Prepare for input
    @unpack lattice, positions, types, _ = get_ccell(cell)
    mesh = Base.cconvert(Vector{Cint}, mesh)
    is_shift = Base.cconvert(Vector{Cint}, is_shift)
    is_time_reversal = Base.cconvert(Cint, is_time_reversal)
    number = Base.cconvert(Cint, length(types))
    # Prepare for output
    npoints = prod(mesh)
    grid_address = zeros(Cint, 3, npoints)  # Julia stores multi-dimensional data in column-major, not row-major (C-style) in memory.
    grid_mapping_table = zeros(Cint, npoints)
    num_ir = ccall(
        (:spg_get_ir_reciprocal_mesh, libsymspg),
        Cint,
        (
            Ptr{Cint},
            Ptr{Cint},
            Ptr{Cint},
            Ptr{Cint},
            Cint,
            Ptr{Cdouble},
            Ptr{Cdouble},
            Ptr{Cint},
            Cint,
            Cdouble,
        ),
        grid_address,
        grid_mapping_table,
        mesh,
        is_shift,
        is_time_reversal,
        lattice,
        positions,
        types,
        number,
        symprec,
    )
    @assert num_ir > 0 "Something wrong happens when finding mesh!"
    return num_ir, grid_mapping_table, grid_address
end
end

function get_stabilized_reciprocal_mesh(
    rotations::AbstractVector{AbstractMatrix{<:Integer}},
    grid::AbstractVector{<:Integer},
    shift::AbstractVector{<:Integer} = [0, 0, 0];
    qpoints = [[0, 0, 0]],
    is_time_reversal = true,
)
    @assert(length(grid) == length(shift) == 3)
    @assert(all(isone(x) || iszero(x) for x in shift))
    @assert(size(qpoints, 2) == 3)
    npoints = prod(grid)
    grid_address = Matrix{Cint}(undef, npoints, 3)
    mapping = Vector{Cint}(undef, npoints)
    exitcode = ccall(
        (:spg_get_stabilized_reciprocal_mesh, libsymspg),
        Cint,
        (
            Ptr{Cint},
            Ptr{Cint},
            Ptr{Cint},
            Ptr{Cint},
            Cint,
            Cint,
            Ptr{Cint},
            Cint,
            Ptr{Cint},
        ),
        grid_address,
        mapping,
        grid,
        shift,
        is_time_reversal,
        length(rotations),
        rotations,
        length(qpoints),
        qpoints,
    )
    @assert(exitcode > 0, "Something wrong happens when finding mesh!")
    return mapping, grid_address
end

"""
    get_multiplicity(cell::Cell, symprec = 1e-8)

Return the exact number of symmetry operations. An error is thrown when it fails.
"""
function get_multiplicity(cell::Cell, symprec = 1e-8)
    @unpack lattice, positions, numbers = get_ccell(cell)
    nsymops = ccall(
        (:spg_get_multiplicity, libsymspg),
        Cint,
        (Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cint}, Cint, Cdouble),
        lattice,
        positions,
        numbers,
        length(numbers),
        symprec,
    )
    nsymops == 0 && error("Could not determine the multiplicity!")
    return nsymops
end

function Base.convert(::Type{Dataset}, dataset::SpglibDataset)
    return Dataset(
        dataset.spacegroup_number,
        dataset.hall_number,
        convert_field(dataset.international_symbol),
        convert_field(dataset.hall_symbol),
        convert_field(dataset.choice),
        collect(Iterators.partition(dataset.transformation_matrix, 3)),
        collect(dataset.origin_shift),
        dataset.n_operations,
        collect(Iterators.partition(unsafe_load(dataset.rotations), 3)),
        collect(unsafe_load(dataset.translations)),
        dataset.n_atoms,
        unsafe_load(dataset.wyckoffs),
        unsafe_load(dataset.site_symmetry_symbols),
        unsafe_load(dataset.equivalent_atoms),
        unsafe_load(dataset.mapping_to_primitive),
        dataset.n_std_atoms,
        collect(Iterators.partition(dataset.std_lattice, 3)),
        unsafe_load(dataset.std_types),
        collect(dataset.std_positions),
        collect(Iterators.partition(unsafe_load(dataset.std_rotation_matrix), 3)),
        unsafe_load(dataset.std_mapping_to_primitive),
        convert_field(dataset.pointgroup_symbol),
    )
end
function Base.convert(::Type{SpaceGroup}, spgtype::SpglibSpacegroupType)
    f = name -> getfield(spgtype, name) |> convert_field
    # Reference: https://discourse.julialang.org/t/construct-an-immutable-type-from-a-dict/26709/2
    return SpaceGroup(map(f, fieldnames(SpaceGroup))...)
end

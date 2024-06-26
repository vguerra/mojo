# ===----------------------------------------------------------------------=== #
# Copyright (c) 2024, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""Implements StaticTuple, a statically-sized uniform container.

You can import these APIs from the `utils` package. For example:

```mojo
from utils.static_tuple import StaticTuple
```
"""

from memory.unsafe import Pointer

from utils.loop import unroll

# ===----------------------------------------------------------------------===#
# Utilities
# ===----------------------------------------------------------------------===#


@always_inline
fn _set_array_elem[
    index: Int,
    size: Int,
    type: AnyRegType,
](
    val: type,
    inout array: __mlir_type[`!pop.array<`, size.value, `, `, type, `>`],
):
    """Sets the array element at position `index` with the value `val`.

    Parameters:
        index: the position to replace the value at.
        size: the size of the array.
        type: the element type of the array

    Args:
        val: the value to set.
        array: the array which is captured by reference.
    """
    var ptr = __mlir_op.`pop.array.gep`(
        Pointer.address_of(array).address, index.value
    )
    __mlir_op.`pop.store`(val, ptr)


@always_inline
fn _create_array[
    size: Int, type: AnyRegType
](lst: VariadicList[type]) -> __mlir_type[
    `!pop.array<`, size.value, `, `, type, `>`
]:
    """Sets the array element at position `index` with the value `val`.

    Parameters:
        size: the size of the array.
        type: the element type of the array

    Args:
        lst: the list of values to set.

    Returns:
        The array with values filled from the input list.
    """
    debug_assert(size == len(lst), "mismatch in the number of elements")

    if len(lst) == 1:
        return __mlir_op.`pop.array.repeat`[
            _type = __mlir_type[`!pop.array<`, size.value, `, `, type, `>`]
        ](lst[0])

    else:
        var array = __mlir_op.`kgen.undef`[
            _type = __mlir_type[`!pop.array<`, size.value, `, `, type, `>`]
        ]()

        @always_inline
        @parameter
        fn fill[idx: Int]():
            _set_array_elem[idx, size, type](lst[idx], array)

        unroll[fill, size]()
        return array


# ===----------------------------------------------------------------------===#
# StaticTuple
# ===----------------------------------------------------------------------===#


fn _static_tuple_construction_checks[size: Int]():
    """Checks if the properties in `StaticTuple` are valid.

    Validity right now is just ensuring the number of elements is > 0.

    Parameters:
      size: The number of elements.
    """
    constrained[size > 0, "number of elements in `StaticTuple` must be > 0"]()


@value
@register_passable("trivial")
struct StaticTuple[element_type: AnyRegType, size: Int](Sized):
    """A statically sized tuple type which contains elements of homogeneous types.

    Parameters:
        element_type: The type of the elements in the tuple.
        size: The size of the tuple.
    """

    alias type = __mlir_type[
        `!pop.array<`, size.value, `, `, Self.element_type, `>`
    ]
    var array: Self.type
    """The underlying storage for the static tuple."""

    @always_inline
    fn __init__() -> Self:
        """Constructs an empty (undefined) tuple.

        Returns:
            The tuple.
        """
        _static_tuple_construction_checks[size]()
        return Self {array: __mlir_op.`kgen.undef`[_type = Self.type]()}

    @always_inline
    fn __init__(*elems: Self.element_type) -> Self:
        """Constructs a static tuple given a set of arguments.

        Args:
            elems: The element types.

        Returns:
            The tuple.
        """
        _static_tuple_construction_checks[size]()
        return Self {array: _create_array[size](elems)}

    @always_inline
    fn __init__(values: VariadicList[Self.element_type]) -> Self:
        """Creates a tuple constant using the specified values.

        Args:
            values: The list of values.

        Returns:
            A tuple with the values filled in.
        """
        _static_tuple_construction_checks[size]()
        return Self {array: _create_array[size, Self.element_type](values)}

    @always_inline("nodebug")
    fn __len__(self) -> Int:
        """Returns the length of the array. This is a known constant value.

        Returns:
            The size of the list.
        """
        return size

    @always_inline("nodebug")
    fn __getitem__[index: Int](self) -> Self.element_type:
        """Returns the value of the tuple at the given index.

        Parameters:
            index: The index into the tuple.

        Returns:
            The value at the specified position.
        """
        constrained[index < size]()
        var val = __mlir_op.`pop.array.get`[
            _type = Self.element_type,
            index = index.value,
        ](self.array)
        return val

    @always_inline("nodebug")
    fn __setitem__[index: Int](inout self, val: Self.element_type):
        """Stores a single value into the tuple at the specified index.

        Parameters:
            index: The index into the tuple.

        Args:
            val: The value to store.
        """
        constrained[index < size]()
        _set_array_elem[index, size, Self.element_type](val, self.array)

    @always_inline("nodebug")
    fn __getitem__[intable: Intable](self, index: intable) -> Self.element_type:
        """Returns the value of the tuple at the given dynamic index.

        Parameters:
            intable: The intable type.

        Args:
            index: The index into the tuple.

        Returns:
            The value at the specified position.
        """
        var offset = int(index)
        debug_assert(offset < size, "index must be within bounds")
        # Copy the array so we can get its address, because we can't take the
        # address of 'self' in a non-mutating method.
        # TODO(Ownership): we should be able to get const references.
        var arrayCopy = self.array
        var ptr = __mlir_op.`pop.array.gep`(
            Pointer.address_of(arrayCopy).address, offset.value
        )
        return Pointer(ptr).load()

    @always_inline("nodebug")
    fn __setitem__[
        intable: Intable
    ](inout self, index: intable, val: Self.element_type):
        """Stores a single value into the tuple at the specified dynamic index.

        Parameters:
            intable: The intable type.

        Args:
            index: The index into the tuple.
            val: The value to store.
        """
        var offset = int(index)
        debug_assert(offset < size, "index must be within bounds")
        var ptr = __mlir_op.`pop.array.gep`(
            Pointer.address_of(self.array).address, offset.value
        )
        Pointer(ptr).store(val)

    fn as_ptr(inout self) -> Pointer[Self.element_type]:
        """Get a mutable pointer to the elements contained by this tuple.

        Returns:
            A pointer to the elements contained by this tuple.
        """

        var base_ptr = Pointer[Self.type].address_of(self.array).address
        var ptr = __mlir_op.`pop.array.gep`(base_ptr, Int(0).value)
        return Pointer(ptr)

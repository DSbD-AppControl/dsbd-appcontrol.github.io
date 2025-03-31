---
title: Towards a better memory management API - Part 2
author: Cristian Urlea
tags: morello-hat
---

## Abstract 

Currently, the Morello stack supports C and C++ and as such, the capability API is very low-level and pointer-oriented. There are, however, many promising modern languages with fast-growing popularity (e.g. Go, Rust, Dart, etc.) that are not pointer-based and have different type systems and memory management strategies.

This raises the question of how to best support such languages such languages on CHERI-extended architectures, and in particular if we can design better APIs for memory management such that these languages can make better use of CHERI capabilities.

In this post we investigate the current approaches to memory allocation in slightly more detail, and explore some options for designing a better, more intentional, memory management API.

## Memory Management Automation (Continued)

In the first part we briefly touched upon Garbage Collection, Resource Acquisition Is Initialization (RAII) and reference counting, techniques used to automatically manage heap memory. Comparing these to stack allocation, we note that such techniques are more complicated to use. There are in fact middle-of-the-road solutions that leverage the structure of stack allocation and deallocation to simplify heap management. 


<!-- https://doc.rust-lang.org/std/boxed/index.html -->

The first of these is the `Box<T>` standard library type which provides the simplest form of heap allocation. A `Box<T>` serves as a reference to a value of type `T`, and can be obtained through a call to `Box::new(value)`. The returned reference ensures the associated memory is freed whenever it goes out of scope by implementing the **Drop** trait.  The lifetime of a boxed value can be extended beyond the initial scope through Rust's **Move Semantics**. 

<!-- A significant limitation pertaining to boxed values is that the reference to the value is unique, meaning there can only -->
<!-- boxed are aligned and will be freed by the global allocator discussed later  -->

<!-- In this part we continue... -->
<!-- https://doc.rust-lang.org/std/mem/union.MaybeUninit.html -->

<!-- MaybeUninit<T> -->

## Rust Allocator API 

The Rust programming language is in certain ways quite modular and configurable. For example, custom memory allocators can plugged in and used even within standard library code, by registering them as the `default global allocator`. Such allocators must implement the `GlobalAlloc` and  `Allocator` APIs.


```Rust
pub unsafe trait GlobalAlloc {
    // Required methods
    unsafe fn alloc(&self, layout: Layout) -> *mut u8;
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout);

    // Provided methods
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 { ... }
    unsafe fn realloc(
        &self,
        ptr: *mut u8,
        layout: Layout,
        new_size: usize
    ) -> *mut u8 { ... }
}
```
<center><b>Listing 1. </b> GlobalAlloc API. </center>

The `GlobalAlloc` API  corresponds to the usual memory allocation API we're all used to in C/C++, consisting of `malloc()`, `calloc()`, `realloc()` and `free()`.

### The Allocator Trait

The newer `Allocator` trait brings a number of improvements, such as providing different methods to `grow()` and `shrink()` an allocation instead of an amalgamated `realloc()` method.


```Rust
pub unsafe trait Allocator {
    // Required methods
    fn allocate(&self, layout: Layout) -> Result<NonNull<[u8]>, AllocError>;
    unsafe fn deallocate(&self, ptr: NonNull<u8>, layout: Layout);

    // Provided methods
    fn allocate_zeroed(
        &self,
        layout: Layout
    ) -> Result<NonNull<[u8]>, AllocError> { ... }
    unsafe fn grow(
        &self,
        ptr: NonNull<u8>,
        old_layout: Layout,
        new_layout: Layout
    ) -> Result<NonNull<[u8]>, AllocError> { ... }
    unsafe fn grow_zeroed(
        &self,
        ptr: NonNull<u8>,
        old_layout: Layout,
        new_layout: Layout
    ) -> Result<NonNull<[u8]>, AllocError> { ... }
    unsafe fn shrink(
        &self,
        ptr: NonNull<u8>,
        old_layout: Layout,
        new_layout: Layout
    ) -> Result<NonNull<[u8]>, AllocError> { ... }
    fn by_ref(&self) -> &Self
       where Self: Sized { ... }
}
```
<center><b>Listing 2. </b> Allocator API. </center>

Another important improvement is that the `Allocator` trait now gives us a way to safely grow an allocation without having to worry about tainted memory using `grow_zeroed()`.

Notice that the standard allocator functions also take `Layout` parameters that specify the size and alignment requirements for the allocations that are to be created, and crucially, those that are to be modified as well.

<!-- https://doc.rust-lang.org/std/alloc/trait.Allocator.html -->

```Rust 
pub struct Layout {
    // size of the requested block of memory, measured in bytes.
    size: usize,
    // alignment of the requested block of memory, measured in bytes.
    // we ensure that this is always a power-of-two [...]
    align: Alignment,
}
```

This showcases the use of an important security and safety principle: that of intentionality. The requirement that we pass a `Layout` parameter when deallocation memory makes it less likely that the programmer will attempt to de-allocate using a pointer that was not sourced from the same allocator: a pointer could be sourced from just about anywhere, whereas an accompanying `Layout` value will most likely come from the same area of code where the memory was initially allocated.


Taking a closer look at the Allocator API we notice more safety features. The `Result<NonNull<[u8]>, AllocError>` return type for `allocate()` indicates that memory allocation can only lead to one of two mutually-exclusive scenarios: 

1. Allocation is successful, in which case the resulting pointer can not be the *null pointer*. 
2. An error occurs, in which case a value of tpe `AllocError` is returned. 

In a similar fashion, the `deallocate()` method requires a non-null pointer as a parameter, indicating that only valid allocations can be deallocated. 

### Going further with CHERI

On CHERI-extended hardware architectures, capability pointers encode information that is normally conveyed through both the pointer (`*mut u8`) and the layout  (`Layout`) types. This state of fact brings with it a series of opportunities and challenges in relation to the memory allocation API. 

Neglecting non-cheri platforms and some of the finer points around alignment for a moment, the `Allocator` trait could be greatly simplified. Methods such as `deallocate()` and `shrink()` that currently take `Layout` parameter which specifies the size of the allocation which is to be modified could simply take in a capability pointer. This brings with it additional safety in that capability pointers can not be forged, unlike `Layout` values which can be constructed by calling `from_size_align(size:usize, align:usize)`.

Another safety improvement to the API, although one that wouldn't necessarily have an impact of the method signature, is that the `shrink()` method taking a capability pointer as an argument would be guaranteed to return a capability pointer with smaller (or equal but not greater) bounds, simply by virtue of how capability pointers operate. The related `grow()` method would require a signature change: the addition of a further capability pointer parameter authorizing the change. 

The changes suggested thus far relate only to the most trivial of use-cases. The most significant limitation related to CHERI capability pointers is that pointer revocation is costly in terms of performance. With the current memory allocation API, once read access is granted to a capability pointer, if malicious code stashes away copies of that capability pointer, the only resolution is to *stop the world* and *scan large areas of memory* with the aim of manually invalidating any such copies. With a little more creative freedom applied to the allocation API, this does not have to be the case. Let us consider the addition of more specialized methods such as `allocate_nocaps()`.


```Rust
pub unsafe trait Allocator {
    
    // [...]
    fn allocate_nocaps(
        &self,
        layout: Layout
    ) -> Result<NoCaps<[u8]>, AllocError> { ... };
    // [...]
}
```
<center><b>Listing 3. </b> Allocator API addition: `allocate_nocaps()`. </center>

The addition of an `allocate_nocaps()` method that returns a capability pointer lacking the `StoreCap` and `LoadCap` permissions would enable secure software implementations to safely exclude regions of memory from the capability scanning operation during capability revocation. Exposing the lack of such permissions through Rust's type system indicated by the hypothetical `NoCaps` type would further strengthen reasoning about such allocations. 

Another non-trivial use-case that warrants closer attention has to do with memory that could potentially hold sensitive information. Current memory allocation APIs provide methods such as `allocate_zeroed()` which provide *integrity* by ensuring that memory is zeroed before use. The *dual* case which requires that memory must be cleared before it is returned to the system, to ensure *privacy* is simply not catered for. Addressing this situation would perhaps require two new methods and some additional type information.  

```Rust
pub unsafe trait Allocator {
    // [...]
    unsafe fn deallocate(&self, ptr: NonNull<u8>, layout: Layout);
    // [...]
    
    fn allocate_mustzero(
        &self,
        layout: Layout
    ) -> Result<MustZero<[u8]>, AllocError> { ... };

    unsafe fn deallocate_zeroed(&self, ptr: MustZero<u8>, layout: Layout);

    // [...]
}
```
<center><b>Listing 4. </b> Allocator API addition: `allocate_mustzero()` and `deallocate_zero()`. </center>

The reasoning here is that a new `allocate_mustzero()` method would return an allocation of type `MustZero` making it impossible to free the allocation through the usual `deallocate()` method. Instead, the newly added `deallocate_zeroed()` method which accepts a `MustZero` allocation parameter would have to be called, ensuring that memory is zeroed out before it is returned to the system. 

## Behavioral Types  

In the following post we will go over some of the basics of behavioral types and their encoding in the Rust language to see how further performance and security benefits could be derived. 

With a view to that future, let us consider a motivating scenario where a client application makes liberal use of both the existing `allocate_zeroed()` method as well as the newly proposed `deallocate_zeroed()`. Clearly it would be wasteful to zero out memory, upon allocation, if said memory can be guaranteed to have been zeroed out previously, during a deallocation event. 

Optimizing for such scenarios, however, requires more drastic changes to the memory allocation API. 
---
title: Towards a better memory management API - Part 1
author: Cristian Urlea
tags: morello-hat
---

## Abstract 

Currently, the Morello stack supports C and C++ and as such, the capability API is very low-level and pointer-oriented. There are, however, many promising modern languages with fast-growing popularity (e.g. Go, Rust, Dart, etc.) that are not pointer-based and have different type systems and memory management strategies.

This raises the question of how to best support such languages such languages on CHERI-extended architectures, and in particular if we can design better APIs for memory management such that these languages can make better use of CHERI capabilities.

In this post we will go over some of the design considerations hiding behind this question, and attempt to lay the groundwork for better memory management APIs.

## What is CHERI?

The CHERI ISA extension provides strong memory protection features which allow historically memory-unsafe programming languages, such as C and C++, to provide more protection against memory based attacks.  

In CHERI, pointers are replaced by capabilities which include not only the address in memory being pointed to, but also additional metadata such: the allowable bounds, permissions which enable the loading/storing of regular/other capabilities and the execution of code, object tags, and a validity tag.

<center>
```{lang="dot"}
digraph "Morello Capability Layout" {
  // Set overall graph attributes
  graph [rankdir=TB, splines=true, nodesep=0.5, ranksep=0.5];
  node [shape=plaintext, fontname=Arial, fontsize=12];
  edge [fontname=Arial, fontsize=10, arrowhead=vee];
  
  // Memory Layout structure
  MemoryLayout [
    label=<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" ALIGN="LEFT">
      <TR>
        <TD PORT="tag" ALIGN="LEFT" BALIGN="LEFT">Tag (1 bit)</TD>
      </TR>
      <TR>
        <TD PORT="perms"  BALIGN="LEFT">Perms (16 bits)</TD>
        <TD PORT="objtype" BALIGN="LEFT">Object Type (18 bits)</TD>
        <TD PORT="bounds"  BALIGN="LEFT">Bounds (20 bits)</TD>
        <TD PORT="flags" BALIGN="LEFT">Flags (8 bits)</TD>
      </TR>
      <TR>
        <TD PORT="address" BALIGN="LEFT" COLSPAN="4">Address (64 bits)</TD>
      </TR>
    </TABLE>>
  ];
}
```
</center>
<center> <b>Figure 1.</b> Morello Capability Layout</center>



The additional metadata can be accessed from C using a number of compiler builtin functions exposed by the compiler.
The cheri-port of the LLVM compiler, for example, exposes the following accessor builtins.  


```C
    #define cheri_getlen(x)         __builtin_cheri_length_get((x))
    #define cheri_getbase(x)        __builtin_cheri_base_get((x))
    #define cheri_getoffset(x)      __builtin_cheri_offset_get((x))
    #define cheri_getaddress(x)     __builtin_cheri_address_get((x))
    #define cheri_getperm(x)        __builtin_cheri_perms_get((x))
    #define cheri_getsealed(x)      __builtin_cheri_sealed_get((x))
    #define cheri_gettag(x)         __builtin_cheri_tag_get((x))
    #define cheri_gettype(x)        __builtin_cheri_type_get((x))
    #define cheri_andperm(x, y)     __builtin_cheri_perms_and((x), (y))
    #define cheri_clearperm(x, y)   __builtin_cheri_perms_and((x), ~(y))
    #define cheri_cleartag(x)       __builtin_cheri_tag_clear((x))
    #define cheri_incoffset(x, y)   __builtin_cheri_offset_increment((x), (y))
    #define cheri_setoffset(x, y)   __builtin_cheri_offset_set((x), (y))
    #define cheri_setaddress(x, y)  __builtin_cheri_address_set((x), (y))
    #define cheri_seal(x, y)        __builtin_cheri_seal((x), (y))
    #define cheri_unseal(x, y)      __builtin_cheri_unseal((x), (y))
```
  <center> <b>Listing 1.</b> Capability Accessors in C</center>



## Where does memory come from?

If we are to propose a different approach to memory management, we must first understand the exact role of each component in the system. To that end, how exactly does an application acquire memory?



At a high level, we normally think of memory allocation in terms of an application's interaction with the stack and heap, however this picture is incomplete. A part of the application's memory needs to be allocated before execution can even begin, and this is the task of the dynamic loader. 



### The Dynamic Loader 


Whenever a new application is to be executed, the dynamic loader will create a few allocations which serve to hold the executable code, as storage for global variables, and one or more stack areas, depending on the number of threads to be executed as part of the application's process. 

<div>
<center>
```{lang="dot"}
digraph G {
  // Set overall graph attributes
  graph [rankdir=LR, splines=true, nodesep=0.5, ranksep=0.5];
  node [shape=box, style=filled, fontname=Arial, fontsize=12];
  edge [fontname=Arial, fontsize=10, arrowhead=vee];

  // Dynamic Loader node
  DynamicLoader [label="Dynamic Loader", shape=ellipse, fillcolor=lightblue];

  // Memory allocations in a table
  MemorySpace [shape=none, margin=0, label=<
    <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="0">
      <TR>
        <TD PORT="stack" WIDTH="120" HEIGHT="60" BGCOLOR="lightgreen">Stack</TD>
      </TR>
      <TR>
        <TD PORT="code" WIDTH="120" HEIGHT="30" BGCOLOR="lightyellow">Client Code</TD>
      </TR>
      <TR>
        <TD PORT="libs" WIDTH="120" HEIGHT="30" BGCOLOR="lightyellow">Library Code</TD>
      </TR>
    </TABLE>
  >];

  // Connect elements using ports
  DynamicLoader:e -> MemorySpace:stack:w [label="mmap()"];
  DynamicLoader:e -> MemorySpace:code:w [label="mmap()"];
  DynamicLoader:e -> MemorySpace:libs:w [label="mmap()"];
}
```
</center>
<center> <b>Figure 1.</b> Capability Accessors in C</center>
</div>

The dynamic loader will also search for the libraries required to start the application in various entries contained within the `LD_PATH` environment variable and load these into the allocated memory. The allocations are obtained from the operating system using the `mmap()` system call. This takes a number of parameters: 

<div>
```C
    #include <sys/mman.h>

    void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset);
    int munmap(void *addr, size_t length);
```
<center> <b>Listing 2.</b> Syscalls: `mmap()`, "munmap()`. </center>
</div>


The second of these parameters, `int prot`, specifies how the new memory allocation can be used: 

<div>

```Markdown
    |------------|---------------------------|
    | PROT_EXEC  | Pages may be executed.    |
    |------------|---------------------------|
    | PROT_READ  | Pages may be written.     |
    |------------|---------------------------|
    | PROT_WRITE | Pages may be written.     |
    |------------|---------------------------|
    | PROT_NONE  | Pages may not be accessed.|
    |------------|---------------------------| 
```
<center> <b>Listing 3.</b> The `prot` parameter to `mmap(addr, prot, ...)`. </center>
</div>

The allocation into which the executable code is loaded needs to be provisioned using `PROT_EXEC | PROT_WRITE | PROT_READ` which would allow the dynamic loader to first write the executable code, and the execute it. The allocation used as the stack however, only requires `PROT_WRITE | PROT_READ`.



### The Stack Allocator

As an application executes, memory is continuously allocated and de-allocated on the stack, but what really drives this process and what can say about it? 


One important aspect is that stack allocation is entirely automatic: memory is acquired and released as dictated by the applicable function **calling convention**, and thus there is very little that can go wrong, aside from running out of memory.

<div>
<center>
```{lang="dot"}
digraph "Function Call" {
  graph [rankdir=TB, splines=false, nodesep=1.0, ranksep=0.5];
  node [shape=box, fontname=Arial, fontsize=12];
  edge [fontname=Arial, fontsize=10, arrowhead=normal];

  
  Caller:s -> StackPointer:stack:n [style=invis];
  Callee:s -> StackAfter:stack:n [style=invis];

  subgraph function_call {
    rankdir=LR;
    rank=same;
    
    Caller [label="Caller", style=filled, color=lightblue];
    Callee [label="Callee", style=filled, color=lightgreen];

    Caller -> Callee;

  }
  
  subgraph cluster_stacks {
    peripheries=0;
    rank=same;
    newrank=true;
    subgraph cluster_stack_before {
        label="Stack layout (before)";
        labelloc=b;
        peripheries=0;
        rank=same;
        StackPointer [label=<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0">
          <TR><TD WIDTH="120" ALIGN="CENTER" BGCOLOR="orange" PORT="stack">Stack Pointer</TD></TR>
          <TR><TD WIDTH="120" ALIGN="CENTER" BGCOLOR="lightblue">Caller Local Variables</TD></TR>
          <TR><TD WIDTH="120" ALIGN="CENTER" BGCOLOR="lightblue">Return Address</TD></TR>
          <TR><TD WIDTH="120" ALIGN="CENTER" BGCOLOR="lightblue">Caller Parameters</TD></TR>
        </TABLE>>];
    }
    subgraph cluster_stack_after {
      label="Stack layout (after)";
      labelloc=b;
      peripheries=0;
      rank=same; 
      StackAfter [label=<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0">
        <TR><TD WIDTH="120" ALIGN="CENTER" BGCOLOR="orange" PORT="stack">Stack Pointer</TD></TR>
        <TR><TD WIDTH="120" ALIGN="CENTER" BGCOLOR="lightgreen">Callee Local Variables</TD></TR>
        <TR><TD WIDTH="120" ALIGN="CENTER" BGCOLOR="lightgreen">Return Address</TD></TR>
        <TR><TD WIDTH="120" ALIGN="CENTER" BGCOLOR="lightgreen">Callee Parameters</TD></TR>
        <TR><TD WIDTH="120" ALIGN="CENTER" BGCOLOR="lightblue">Caller Local Variables</TD></TR>
        <TR><TD WIDTH="120" ALIGN="CENTER" BGCOLOR="lightblue">Return Address</TD></TR>
        <TR><TD WIDTH="120" ALIGN="CENTER" BGCOLOR="lightblue">Caller Parameters</TD></TR>
      </TABLE>>];
    }
  }
}
```
</center>
<center> <b>Figure 2.</b> Stack allocation is driven by function calls.</center>
</div>

The programmer can indirectly control how the stack allocator behaves. As memory is allocated and de-allocated whenever functions are called, annotating the source-code with `inline` directives can reduce the frequency of these events. 

Stack allocation is typically very quick. On most platforms, stack allocation and de-allocation can boil down to as little as a single instruction code fragments that simply increment or decrement the stack pointer.


### The Heap Allocator

When we talk about memory allocation in C, the first things that might spring to mind are the well known `malloc()` and `free()` functions. These give the programmer direct control of the heap allocation at all times.


```C
    int *arr;
    int size = 256; // Size of the integer array
    // Allocate memory for the integer array
    arr = (int *)malloc(size * sizeof(int));
    // Assign values to the elements of the array
    for (int i = 0; i < size; i++) {
        arr[i] = i * 10;
    }
    // Free the allocated memory
    free(arr);
    // ...
```
<center><b>Listing 4. </b>Typical `malloc(); use(); free()` cycle.</center>

Before we can store anything on the heap, a sufficiently large slice of memory must first be obtained with a call to `malloc()`. Once we are done with the allocation, a call to `free()` will return the slice of memory back to the allocator. 
If for one reason or another, we end up needing to re-size an allocation, a simple call to `realloc()` is all that is needed.


One issue with such direct control over heap allocation is that we might forget to make the appropriate call to `free()`. If this happens sufficiently many times of over the lifetime of an execution, the system can run out of memory and crash.

Likewise, if a heap allocation is freed but still accessible through pointers that have not been cleared at the same time, this can lead to an exploitable `Use-After-Free` vulnerability. 

Heap allocation is riddled with such corner cases and gotchas. Consider for a moment, what might happen if we executed the code in **Listing 2** immediately after that in **Listing 1**. 

```C
    // ... 
    int *arr2;
    arr2 = (int *)malloc(size * sizeof(int));
    // surprise?
    for (size_t i = 0; i < size; i++) {
        printf("%d\n", arr[i]);
    }
```
<center><b>Listing 5. </b> What happened here? </center>

A novice programmer might reasonably expect that `arr2` point to some fresh area of memory and thus be surprised to find that the values previously stored through `arr1` are now accessible again. While stack stack memory is cleared on allocation, the same does not normally hold true for allocations obtained through `malloc()`. 

While it is possible to obtain a heap allocation with zeroed out memory, through a call to `calloc()`, that is not necessarily the most secure course of action.

If we are interested in preserving the **integrity** of our new allocation, then `calloc()` works well for that purpose as memory is zeroed out before a pointer to the allocation is obtained. 

If on the other hand, we would be more interested in preserving **privacy**, that is to say that we are instead concerned with ensuring that the contents stored through `arr1` are never leaked to begin with, then that would call for an alternative implementation for the `free()` function, one which zeros out the memory before it is made available for re-allocation. Sadly no such function is made available through the standard memory allocation API. 

### The Kernel

For most use-cases, memory allocation via the stack and the standard library heap allocator is generally suited, however, there are circumstances where these do not provide enough control to the programmer.

Precise control over memory allocation may be desirable for security or performance reasons. The Linux kernel, for example,  exposes a number of system calls such as: `mmap()`, `mbind()`, `madvise()`, `mprotect()` and `mlock()`, which can be used to fine-tune many of the rich memory allocation policy features available. 

The `mmap()` system call, accepts an `int prot` argument which may used to specify whether or not the returned memory mapping allows the contents to be read, written or executed. 

This feature is implemented on some platforms using the **No-Execute Bit (NX bit)**, a crucial security feature of most modern architectures that prevents the execution of code stored in particular regions of memory designated for data storage. 

This mechanism prevents certain common security vulnerabilities such as the use of `buffer overflow` and `code injection` attacks to trigger the execution of malicious code. The standard memory allocation and de-allocation functions such as `malloc()` and `free()` do not expose enough functionality to make use of the `NX bit`. 

The `mbind()` and `madvise()` syscalls can be used to improve performance, the former being used to tweak the non-uniform memory access policy while the latter allows a running program to inform the kernel that a particular memory access pattern is likely to occur in the near future, thus allowing the kernel to make better use of prefetching. 



### Memory Management Automation 

#### Garbage Collection

Many programming languages make use of Garbage Collection (GC), which provides automatic (heap) memory management. Instead of giving the programmer explicit control over memory allocation, the system assumes that such events are to be implied by certain language constructs, such as the `new` keyword in Java. 

```Java
public void foo() {
    // Memory allocation for obj1
    MyClass obj1 = new MyClass();
    return; // Possible deallocation for obj1
} 
```
<center><b>Listing 6. </b> The `new` keyword in Java allocates memory. </center>

Similarly, exact control over memory deallocation withheld from the programmer, and instead, the garbage collector runs periodically to free up any memory that can be safely determined to be no longer needed. In the example shown, `obj1` goes out of scope as soon as the function returns.


Automatically determining when it is safe to free memory can be a challenging task indeed. A simple GC implementation might scan the entire memory contents of an application for references to an allocation, and if none can be found, mark the allocation as being safe to reclaim. This strategy for GC is commonly known as _mark and sweep_. 


In practice, a simple GC strategy as previously described will deliver fairly poor performance. Scanning the entire contents of an application's memory for references can take some time, during which, the application typically needs to be prevented from executing such that race between it and the GC do not lead to an unsound state.


Fortunately, there are many improvements to this simple strategy that can be used in speed up garbage collection. Examples include `Concurrent GC` and `Generational GC`. What interests us more is the dependency of such strategies upon the structure and semantics of the programming language being used. 

The **Dart** programming language, for example, makes use of both **Strong** and **Weak** references. The difference between the two is that the existence of a single `Strong References` to some object is sufficient to prevent the Dart GC from freeing the allocation, whereas the existence of any number of `Weak references` would not. 


#### Tracking Ownership


##### Resource Acquisition Is Initialization

In languages such as C++ that do not have a garbage collector, it is desirable to avoid heap allocations CHERI

This is made possible by the fact that heap allocations can be related to stack allocations. If, for example, a single reference to some heap allocation exists within a particular function's stack frame, then whenever such a function returns, the stack shrinks and the reference disappears, allowing the associated heap allocation to be freed.

To this end, Rust implements an ownership model, which dictates that all memory allocations have exactly one owner, and that they must be released as soon as their owners are released.


Where Rust really shines is in its ability to keep track of heap allocations across function call boundaries.
Normally, one may thing that every heap allocation would have to be immediately freed upon exit from the scope where the allocation occurred. Fortunately, this is not the case. The type system in Rust implements a `borrow checker` and a `lifetime system` which relax these rules while preserving safety. 


```Rust
fn foo(i: &i32) {
    let answer = 42;
}

fn main() {
    let x = 5;
    let y = &x;

    foo(y);
}
```
<center><b>Listing 7. </b> Lifetimes in Rust. </center>

##### Reference Counting 

As the `lifetime` mechanism in Rust is enforced at compile time, this presents a problem: it requires that memory allocations are used and freed in a Last-In-First-Out order, consistent with the operation of the stack and the borrow rules that apply. The requirement that every allocation have a single owner is particularly troublesome for certain types of application. 

For situations where more flexibility is required, rust provides the `Rc<T>` type which provides a reference counting implementation, allowing for allocations with multiple owners which are safely freed when their owner count drops to zero. 



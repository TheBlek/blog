+++
date = '2025-06-19T18:27:50+03:00'
draft = true
title = 'Parallelizing Haskel Raytracer'
+++

> This is just a translation of my previous article from 2023. While I tried to save style from the orignal, most of it It will not be
substantially expanded upon, although I might add new measurements later. You 
can read original in russian here: https://luxurious-yearde9.notion.site/Parallel-Haskell-raytracer-63132332960f488aaa04b7cc01e13f8e.

# Introduction

So we made a raytracer in haskell using [Raytracing In One Weekend](https://raytracing.github.com) as our guide.
As you may know, haskell's biggest feature is mathematically correct functions. Meaning the result of the evaluation can be determined solely from the arugments. So no more global or hidden state. This computing models lends itself great to parrallel execution. However there were a few unexpected pitfalls that I want to share. 

While measuring performance benefit of parallelizing I also became interested in how fast it can go. Hence a second part about optimisations.

# Baseline measurements
For all measurements I'm going to use three configurations:
```
Small: 11.33s (Avg 3)
Medium: 94.5s (Avg 3)
Big: 408.93s (Just 1)
```
Everything later will be measured one-shot.

# Threads go brrr

Having downloaded package `parallel`, I replaced following line:
```haskell
write_file "output.ppm" (evalState colors (mkStdGen 0))
```
with
```haskell
write_file "output.ppm" (evalState colors (mkStdGen 0) `using` parList rseq)
```
Just calculating an array of colors for each pixel in parallel. And...

12 seconds for small configuration...

And I could see only one thread in htop.

That's because mutlithreading needs to be turned on at compile time:

```
ghc-options: 
    -threaded 
    -rtsopts 
    -with-rtsopts=-N -- Can pass number of threads to limit (-N4)
```

Now we are ready to take off!

![How it look in htop](/haskell-htop.webp)

Looking good!

Wait, what?...

24 seconds on the small test?... From baseline of 11.3?!

Something's wrong here.

This might happen because of resource contension between threads. And we actually have a resource that we "share" - random number generator. We can't generate random numbers for one pixel until we have done so for previous pixel. Otherwise numbers will be the same for each pixel and won't be random. And empirically that leads to artifacts in the image. So what do we when we actually want to share?

> Looking at this code now in 2025, I'm not sure anymore what caused such a massive slowdown. Maybe it's because of spawning so many thread simutaneously? I mean, obviously, it wasn't "sharing". Remember - no direct sharing in haskell. However, fundamentally we _needed_ to share pRNG. And that certainly is a limiter. I'm not even sure what the code written the first time parallelized...

Our case is pretty simple - we can create any number of pRNGs and use each of them sequentially:

```haskell
let accumulated_color = [multi_color objs u v (floor samples_per_pixel)|
            v <-  reverse [0, 1/(image_height - 1)..1], 
            u <-  [0, 1/(image_width - 1)..1]]

let len = image_height * image_width
let part_len = len / 4
let map_colors = mapM (fmap (adjust_gamma 2 . average samples_per_pixel))
let st_colors = map map_colors (chunksOf (floor part_len) accumulated_color)

let colors_parts = zipWith (\st i -> evalState st (mkStdGen i)) st_colors [0..]
let colors = concat (colors_parts `using` parList rseq)
write_file "output.ppm" colors
```

Running small test we get 13 seconds. That's better, but still bad. What am I doing wrong?

## Haskell is a lazy capybara

Turns out, problem was because of haskell does not evaluate anything immediately. It stores objects that describe the calculation that is evaluated on demand.

```haskell
ghci> let x = 1 + 2 :: Int
ghci> :sprint x
x = _
ghci> seq x ()
()
ghci> :sprint x
x = 3
```

That also applies to _constructors of types_:

```haskell
ghci> let x = 1 + 2 :: Int
ghci> let z = swap (x, x+1)
ghci> :sprint z
z = _
ghci> seq z ()
()
ghci> :sprint z
z = (_,_)
```

As you can notice, field values remain uncomputed. As it turns out, `seq` will not go deeper than one level. To compute field values, you need to demand them:

```haskell
ghci> fst z
4
ghci> :sprint z
z = (4,3)
```

In this case, first field (x + 1) was dependent upon evaluation of x so haskell automatically calculated x. And second field happened to be x, hence its evaluated.

The function that we used to calculate list in parallel - `parList` - just uses `seq` on each of the list element in parallel. You can probably see the problem: 

```haskell
data Color = Cl {color::Vec3}
---
ghci> let color = blue
ghci> :sprint color
color = _
ghci> seq color ()
color = Cl _
---
[Cl _, Cl _, ...]
```

And actual colors were calculated when function writing the image needed them.

For solving this problem there is a class `RNFData` in the `deepseq` package. This class has a single function that has to make haskell evaluate a value completely. For parallelizing computation of colors we needed to specify the behaviour for our types:

```haskell
instance NFData Color where 
    rnf (Cl x) = rnf x

instance NFData Vec3 where
    rnf (Vc3 x y z) = seq x $ seq y $ seq z ()
```

Then replace one line:

```haskell
let colors = concat (colors_parts `using` parList rdeepseq)
```

And finally a W:

```
Small: 8s (~1.41x)
Medium: 64s (~1.47x)
Big: 277s (~1.48x)
```

For a machine with two real cores, the result looks as expected.

# Optimisations go brrr

```c
int main() {
    return 0;
}
```

## Another point

[link](https://google.com)

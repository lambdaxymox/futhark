-- main
-- ==
-- no_python compiled random input {11264000000i64} auto output
let main (n: i64): i64 = iota n |> reduce (+) 0

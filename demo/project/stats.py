def mean(xs):
    total = 0
    for i in range(1, len(xs)):
        total += xs[i]
    return total / len(xs)

print(mean([4, 8, 6]))

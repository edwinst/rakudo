# Waits for a promise to be kept or a channel to be able to receive a value
# and, once it can, unwraps or returns the result. This should be made more
# efficient by using continuations to suspend any task running in the thread
# pool that blocks; for now, this cheat gets the basic idea in place.

proto sub await(|) { * }
multi sub await(Promise $p) {
    $p.result
}
multi sub await(*@awaitables) {
    @awaitables.eager.map(&await)
}
multi sub await(Channel $c) {
    $c.receive
}

my constant $WINNER_KIND_DONE = 0;
my constant $WINNER_KIND_MORE = 1;

sub WINNER(@winner, *@other, :$wild_done, :$wild_more, :$wait, :$wait_time is copy) {
    my Num $until = $wait ?? nqp::time_n() + $wait !! Nil;

    sub invoke_right(&block, $key, $value?) {
        my @names = map *.name, &block.signature.params;
        return do if @names eqv ['$k', '$v'] || @names eqv ['$v', '$k'] {
            &block(:k($key), :v($value));
        } elsif @names eqv ['$_'] || (+@names == 1 && &block.signature.params[0].positional)  {
            &block($value);
        } elsif @names eqv ['$k'] {
            &block(:k($key));
        } elsif @names eqv ['$v'] {
            &block(:v($value));
        } elsif +@names == 0 {
            return &block();
        } else {
            die "Couldn't figure out how to invoke {&block.signature().perl}";
        }
    }

    my @todo;
#       |-- [ kind, contestant, block, alternate_block? ]

    # sanity check and transmogrify possibly multiple promises into things to do
    while +@other {
        my $kind = @other.shift;
        if $kind != $WINNER_KIND_DONE && $kind != $WINNER_KIND_MORE {
            die "Got a {$kind.WHAT.perl}, but expected $WINNER_KIND_DONE or $WINNER_KIND_MORE";
        }

        my @contestant = @other.shift;
        while @other[0] !~~ Block {
            my $next := @other.shift;
            if $next !~~ Promise && $next !~~ Channel {
                die "Got a {$next.WHAT.perl}, but expected a Promise or Channel";
            }
            elsif $kind == $WINNER_KIND_MORE && $next ~~ Promise {
                die "Cannot use 'more' on a Promise";
            }
            push @contestant, $next;
        }
        my &block = @other.shift;

        @todo.push: [ $kind, $_, &block ] for @contestant;
    }

    # transmogrify any winner spec if nothing to do so far
    if !@todo {
        for @winner {
            when Promise {
                @todo.push: [ $WINNER_KIND_DONE, $_, $wild_done ];
            }
            when Channel {
                @todo.push: [ $WINNER_KIND_MORE, $_, $wild_more, $wild_done ];
            }
            default {
                die "Got a {$_.WHAT.perl}, but expected a Promise or Channel";
            }
        }
    }

    if !@todo {
        die "Nothing todo for winner";
    }

    my $action;
    my $timeout_promise;

    CHECK:
    loop {  # until something to return
        my @promises;
        my Bool $must_yield;

        for @todo.pick(*) -> $todo {
            my $kind       := $todo[0];
            my $contestant := $todo[1];

            if $kind == $WINNER_KIND_DONE {

                if $contestant ~~ Promise {
                    if $contestant {   # kept/broken
                        $action = 
                          {invoke_right($todo[2],$contestant,$contestant.result)};
                        last; # CHECK;
                    }
                    @promises.push: $contestant;
                }

                else {   # Channel
                    if $contestant.closed {
                        $action = {invoke_right($todo[2], $contestant)};
                        last; # CHECK;
                    }
                }
            }

            else { # $kind == $WINNER_KIND_MORE && $contestant ~~ Channel

                if (my $value := $contestant.poll) !~~ Nil {
                    $action = {invoke_right($todo[2], $contestant, $value)};
                    last; # CHECK;
                }

                elsif $contestant.closed && $todo[3] {
                    $action = {invoke_right($todo[3], $contestant)};
                    last; # CHECK;
                }
                $must_yield = True;
            }
        }

        last if $action; # remove if we can last to CHECK:

        # we have to wait
        if $until {
            if $nqp::time_n() >= $until {  # we're done waiting
                $action = $wait;
                last; # CHECK;
            }
            
            # make sure we wait next time
            @promises.push: $timeout_promise //= Promise.at($until);
        }

        # yield the thread only if we must
        $must_yield
          ?? Thread.yield()
          !! Promise.anyof(|@promises).result;
    }

    # must do action outside above loop to make any "last" in block find the right loop
    $action();
}
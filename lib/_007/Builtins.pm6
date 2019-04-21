use _007::Val;
use _007::Value;
use _007::Q;
use _007::OpScope;
use _007::Equal;

class X::Control::Exit is Exception {
    has Int $.exit-code;
}

sub wrap($_) {
    when Nil  { NONE }
    when Bool { Val::Bool.new(:value($_)) }
    when Str  { Val::Str.new(:value($_)) }
    when Array | Seq | List { Val::Array.new(:elements(.map(&wrap))) }
    default { die "Got some unknown value of type ", .^name }
}

subset ValOrQ of Any where Val | Q;

sub assert-type(:$value, ValOrQ:U :$type, Str :$operation) {
    die X::TypeCheck.new(:$operation, :got($value), :expected($type))
        unless $value ~~ $type;
}

sub assert-new-type(:$value, :$type, Str :$operation) {
    my $type-obj = $type ~~ Str
        ?? (TYPE{$type} or die "Type not found: {$type}")
        !! is-type($type)
            ?? $type
            !! $type ~~ _007::Value
                ?? die X::TypeCheck.new(:$operation, :got($value.type), :expected($type))
                !! die X::TypeCheck.new(:$operation, :got($value), :expected($type));
    die X::TypeCheck.new(:$operation, :got($value), :expected($type-obj))
        unless $value ~~ _007::Value && $value.type === $type-obj;
}

sub assert-nonzero(:$value, :$operation, :$numerator) {
    die X::Numeric::DivideByZero.new(:using($operation), :$numerator)
        if $value == 0;
}

multi less-value($l, $) {
    assert-new-type(:value($l), :type<Int>, :operation<less>);
}
multi less-value(_007::Value::Backed $l, _007::Value::Backed $r) {
    is-int($l) && is-int($r) && $l.native-value < $r.native-value;
}
multi less-value(Val::Str $l, Val::Str $r) { $l.value lt $r.value }

multi more-value($l, $) {
    assert-new-type(:value($l), :type<Int>, :operation<more>);
}
multi more-value(Val::Str $l, Val::Str $r) { $l.value gt $r.value }
multi more-value(_007::Value::Backed $l, _007::Value::Backed $r) {
    is-int($l) && is-int($r) && $l.native-value > $r.native-value;
}

my role Placeholder {
    has $.qtype;
    has $.assoc;
    has %.precedence;
}
my class Placeholder::MacroOp does Placeholder {
}
sub macro-op(:$qtype, :$assoc?, :%precedence?) {
    Placeholder::MacroOp.new(:$qtype, :$assoc, :%precedence);
}

my class Placeholder::Op does Placeholder {
    has &.fn;
}
sub op(&fn, :$qtype, :$assoc?, :%precedence?) {
    Placeholder::Op.new(:&fn, :$qtype, :$assoc, :%precedence);
}

my @builtins =
    say => -> *$args {
        # implementation in Runtime.pm
    },
    prompt => sub ($arg) {
        # implementation in Runtime.pm
    },
    type => -> $arg {
        $arg ~~ _007::Value
            ?? $arg.type
            !! Val::Type.of($arg.WHAT);
    },
    exit => -> $int = make-int(0) {
        assert-new-type(:value($int), :type<Int>, :operation<exit>);
        my $exit-code = $int.native-value % 256;
        die X::Control::Exit.new(:$exit-code);
    },
    assertType => -> $value, $type {
        if $type ~~ _007::Value {
            assert-new-type(:value($type), :type<Type>, :operation("assertType (checking the Type parameter)"));
            assert-new-type(:$value, :type($type), :operation<assertType>);
        }
        else {
            assert-type(:value($type), :type(Val::Type), :operation("assertType (checking the Type parameter)"));
            assert-type(:$value, :type($type.type), :operation<assertType>);
        }
    },

    # OPERATORS (from loosest to tightest within each category)

    # assignment precedence
    'infix:=' => macro-op(
        :qtype(Q::Infix::Assignment),
        :assoc<right>,
    ),

    # disjunctive precedence
    'infix:||' => macro-op(
        :qtype(Q::Infix::Or),
    ),
    'infix://' => macro-op(
        :qtype(Q::Infix::DefinedOr),
        :precedence{ equiv => "infix:||" },
    ),

    # conjunctive precedence
    'infix:&&' => macro-op(
        :qtype(Q::Infix::And),
    ),

    # comparison precedence
    'infix:==' => op(
        sub ($lhs, $rhs) {
            my %*equality-seen;
            return wrap(equal-value($lhs, $rhs));
        },
        :assoc<non>,
    ),
    'infix:!=' => op(
        sub ($lhs, $rhs) {
            my %*equality-seen;
            return wrap(!equal-value($lhs, $rhs))
        },
        :precedence{ equiv => "infix:==" },
    ),
    'infix:<' => op(
        sub ($lhs, $rhs) {
            return wrap(less-value($lhs, $rhs))
        },
        :precedence{ equiv => "infix:==" },
    ),
    'infix:<=' => op(
        sub ($lhs, $rhs) {
            my %*equality-seen;
            return wrap(less-value($lhs, $rhs) || equal-value($lhs, $rhs))
        },
        :precedence{ equiv => "infix:==" },
    ),
    'infix:>' => op(
        sub ($lhs, $rhs) {
            return wrap(more-value($lhs, $rhs) )
        },
        :precedence{ equiv => "infix:==" },
    ),
    'infix:>=' => op(
        sub ($lhs, $rhs) {
            my %*equality-seen;
            return wrap(more-value($lhs, $rhs) || equal-value($lhs, $rhs))
        },
        :precedence{ equiv => "infix:==" },
    ),
    'infix:~~' => op(
        sub ($lhs, $rhs) {
            if is-type($rhs) {
                return wrap($lhs ~~ _007::Value && $lhs.type === $rhs);
            }
            assert-type(:value($rhs), :type(Val::Type), :operation<~~>);

            return wrap($rhs.type ~~ Val::Object || $lhs ~~ $rhs.type);
        },
        :precedence{ equiv => "infix:==" },
    ),
    'infix:!~~' => op(
        sub ($lhs, $rhs) {
            if is-type($rhs) {
                return wrap($lhs !~~ _007::Value || $lhs.type !=== $rhs);
            }
            assert-type(:value($rhs), :type(Val::Type), :operation<!~~>);

            return wrap($rhs.type !~~ Val::Object && $lhs !~~ $rhs.type);
        },
        :precedence{ equiv => "infix:==" },
    ),

    # concatenation precedence
    'infix:~' => op(
        sub ($lhs, $rhs) {
            return wrap($lhs.Str ~ $rhs.Str);
        },
    ),

    # additive precedence
    'infix:+' => op(
        sub ($lhs, $rhs) {
            assert-new-type(:value($lhs), :type<Int>, :operation<+>);
            assert-new-type(:value($rhs), :type<Int>, :operation<+>);

            return make-int($lhs.native-value + $rhs.native-value);
        },
    ),
    'infix:-' => op(
        sub ($lhs, $rhs) {
            assert-new-type(:value($lhs), :type<Int>, :operation<->);
            assert-new-type(:value($rhs), :type<Int>, :operation<->);

            return make-int($lhs.native-value - $rhs.native-value);
        },
    ),

    # multiplicative precedence
    'infix:*' => op(
        sub ($lhs, $rhs) {
            assert-new-type(:value($lhs), :type<Int>, :operation<*>);
            assert-new-type(:value($rhs), :type<Int>, :operation<*>);

            return make-int($lhs.native-value * $rhs.native-value);
        },
    ),
    'infix:div' => op(
        sub ($lhs, $rhs) {
            assert-new-type(:value($lhs), :type<Int>, :operation<div>);
            assert-new-type(:value($rhs), :type<Int>, :operation<div>);
            assert-nonzero(:value($rhs.native-value), :operation("infix:<div>"), :numerator($lhs.native-value));

            return make-int($lhs.native-value div $rhs.native-value);
        },
    ),
    'infix:divmod' => op(
        sub ($lhs, $rhs) {
            assert-new-type(:value($lhs), :type<Int>, :operation<divmod>);
            assert-new-type(:value($rhs), :type<Int>, :operation<divmod>);
            assert-nonzero(:value($rhs.native-value), :operation("infix:<divmod>"), :numerator($lhs.native-value));

            return Val::Array.new(:elements([
                make-int($lhs.native-value div $rhs.native-value),
                make-int($lhs.native-value % $rhs.native-value),
            ]));
        },
        :precedence{ equiv => "infix:div" },
    ),
    'infix:%' => op(
        sub ($lhs, $rhs) {
            assert-new-type(:value($lhs), :type<Int>, :operation<%>);
            assert-new-type(:value($rhs), :type<Int>, :operation<%>);
            assert-nonzero(:value($rhs.native-value), :operation("infix:<%>"), :numerator($lhs.native-value));

            return make-int($lhs.native-value % $rhs.native-value);
        },
        :precedence{ equiv => "infix:div" },
    ),
    'infix:%%' => op(
        sub ($lhs, $rhs) {
            assert-new-type(:value($lhs), :type<Int>, :operation<%%>);
            assert-new-type(:value($rhs), :type<Int>, :operation<%%>);
            assert-nonzero(:value($rhs.native-value), :operation("infix:<%%>"), :numerator($lhs.native-value));

            return wrap($lhs.native-value %% $rhs.native-value);
        },
        :precedence{ equiv => "infix:div" },
    ),

    # prefixes
    'prefix:~' => op(
        sub prefix-str($expr) {
            Val::Str.new(:value($expr.Str));
        },
    ),
    'prefix:+' => op(
        sub prefix-plus($_) {
            when Val::Str {
                return make-int(.value.Int)
                    if .value ~~ /^ '-'? \d+ $/;
                proceed;
            }
            when _007::Value {
                if is-int($_) {
                    return make-int(.native-value);
                }
                else {
                    proceed;
                }
            }
            assert-new-type(:value($_), :type<Int>, :operation("prefix:<+>"));
        },
    ),
    'prefix:-' => op(
        sub prefix-minus($_) {
            when Val::Str {
                return make-int(-.value.Int)
                    if .value ~~ /^ '-'? \d+ $/;
                proceed;
            }
            when _007::Value {
                if is-int($_) {
                    return make-int(-.native-value);
                }
                else {
                    proceed;
                }
            }
            assert-new-type(:value($_), :type<Int>, :operation("prefix:<->"));
        },
    ),
    'prefix:?' => op(
        sub ($a) {
            return wrap(?$a.truthy)
        },
    ),
    'prefix:!' => op(
        sub ($a) {
            return wrap(!$a.truthy)
        },
    ),
    'prefix:^' => op(
        sub ($n) {
            assert-new-type(:value($n), :type<Int>, :operation("prefix:<^>"));

            return Val::Array.new(:elements((^$n.native-value).map(&make-int)));
        },
    ),

    # postfixes
    'postfix:[]' => macro-op(
        :qtype(Q::Postfix::Index),
    ),
    'postfix:()' => macro-op(
        :qtype(Q::Postfix::Call),
    ),
    'postfix:.' => macro-op(
        :qtype(Q::Postfix::Property),
    ),
;

for Val::.keys.map({ "Val::" ~ $_ }) -> $name {
    my $type = ::($name);
    push @builtins, ($type.^name.subst("Val::", "") => Val::Type.of($type));
}
push @builtins, "Int" => TYPE<Int>;
push @builtins, "Q" => Val::Type.of(Q);

my $opscope = _007::OpScope.new();

sub install-op($name, $placeholder) {
    $name ~~ /^ (prefix | infix | postfix) ':' (.+) $/
        or die "This shouldn't be an op";
    my $type = ~$0;
    my $opname = ~$1;
    my $qtype = $placeholder.qtype;
    my $assoc = $placeholder.assoc;
    my %precedence = $placeholder.precedence;
    $opscope.install($type, $opname, $qtype, :$assoc, :%precedence);
}

my &ditch-sigil = { $^str.substr(1) };
my &parameter = { Q::Parameter.new(:identifier(Q::Identifier.new(:name(Val::Str.new(:$^value))))) };

@builtins.=map({
    when .value ~~ Val::Type {
        .key => .value;
    }
    when is-type(.value) {
        .key => .value;
    }
    when .value ~~ Block {
        my @elements = .value.signature.params».name».&ditch-sigil».&parameter;
        if .key eq "say" {
            @elements = parameter("...args");
        }
        my $parameterlist = Q::ParameterList.new(:parameters(Val::Array.new(:@elements)));
        my $statementlist = Q::StatementList.new();
        .key => Val::Func.new-builtin(.value, .key, $parameterlist, $statementlist);
    }
    when .value ~~ Placeholder::MacroOp {
        my $name = .key;
        install-op($name, .value);
        my @elements = .value.qtype.attributes».name».substr(2).grep({ $_ ne "identifier" })».&parameter;
        my $parameterlist = Q::ParameterList.new(:parameters(Val::Array.new(:@elements)));
        my $statementlist = Q::StatementList.new();
        .key => Val::Func.new-builtin(sub () {}, $name, $parameterlist, $statementlist);
    }
    when .value ~~ Placeholder::Op {
        my $name = .key;
        install-op($name, .value);
        my &fn = .value.fn;
        my @elements = &fn.signature.params».name».&ditch-sigil».&parameter;
        my $parameterlist = Q::ParameterList.new(:parameters(Val::Array.new(:@elements)));
        my $statementlist = Q::StatementList.new();
        .key => Val::Func.new-builtin(&fn, $name, $parameterlist, $statementlist);
    }
    default { die "Unknown type {.value.^name} installed in builtins" }
});

my $builtins-pad = Val::Dict.new;
for @builtins -> Pair (:key($name), :$value) {
    $builtins-pad.properties{$name} = $value;
}

sub builtins-pad() is export {
    return $builtins-pad;
}

sub opscope() is export {
    return $opscope;
}

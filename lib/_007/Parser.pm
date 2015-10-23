use _007::Q;
use _007::Parser::Exceptions;
use _007::Parser::OpLevel;
use _007::Parser::Syntax;
use _007::Parser::Actions;

class _007::Parser {
    has @!oplevels;

    method oplevel { @!oplevels[*-1] }
    method push-oplevel { @!oplevels.push: @!oplevels[*-1].clone }
    method pop-oplevel { @!oplevels.pop }

    submethod BUILD {
        my $opl = _007::Parser::OpLevel.new;
        @!oplevels.push: $opl;

        $opl.install('prefix', '-', Q::Prefix::Minus, :assoc<left>);

        $opl.install('infix', '=', Q::Infix::Assignment, :assoc<right>);
        $opl.install('infix', '==', Q::Infix::Eq, :assoc<left>);
        $opl.install('infix', '+', Q::Infix::Addition, :assoc<left>);
        $opl.install('infix', '~', Q::Infix::Concat, :precedence{ equal => "+" });
    }

    method parse($program, :$*runtime = die "Must supply a runtime") {
        for <prefix infix postfix> -> $type {
            for @!oplevels[0].ops{$type}.keys -> $op {
                my $name = "$type\:<$op>";
                my $sub = $type eq "infix" ?? -> $l, $r {} !! -> $expr {};
                $*runtime.declare-var($name, Val::Sub::Builtin.new($name, $sub));
            }
        }

        my %*assigned;
        my $*insub = False;
        my $*parser = self;
        _007::Parser::Syntax.parse($program, :actions(_007::Parser::Actions))
            or die "Could not parse program";   # XXX: make this into X::
        return $/.ast;
    }
}

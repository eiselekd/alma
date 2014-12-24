use _007::Q;

role Frame {
    has $.block;
    has %.pad;
}

constant NO_OUTER = {};

role Runtime {
    has $.output;
    has @!frames;

    submethod BUILD(:$output) {
        $!output = $output;
        my $setting = Val::Block.new(
            :outer-frame(NO_OUTER));
        self.enter($setting);
        self.load-builtins;
    }

    method run(Q::Statements $statements) {
        my $compunit = Val::Block.new(
            :$statements,
            :outer-frame(self.current-frame));
        self.enter($compunit);
        for $statements.static-lexpad.kv -> $name, $value {
            self.put-var($name, $value);
        }

        $statements.run(self);
        self.leave;
        CATCH {
            when X::Control::Return {
                die X::ControlFlow::Return.new;
            }
        }
    }

    method enter($block) {
        my $frame = Frame.new(:$block);
        @!frames.push($frame);
        for $block.statements.statements -> $statement {
            $statement.declare(self);
        }
    }

    method leave {
        @!frames.pop;
    }

    method unroll-to($frame) {
        until self.current-frame === $frame {
            self.leave;
        }
        return;
    }

    method current-frame {
        @!frames[*-1];
    }

    method !find($symbol) {
        my $frame = self.current-frame;
        loop {
            return $frame.pad
                if $frame.pad{$symbol} :exists;
            $frame = $frame.block.outer-frame;
            last if $frame === NO_OUTER;
        }
        die X::Undeclared.new(:$symbol);
    }

    method put-var($name, $value) {
        my %pad := self!find($name);
        %pad{$name} = $value;
    }

    method get-var($name) {
        my %pad := self!find($name);
        return %pad{$name};
    }

    method declare-var($name) {
        self.current-frame.pad{$name} = Val::None.new;
    }

    method declared($name) {
        try self!find($name) && return True;
        return False;
    }

    method declared-locally($name) {
        my $frame = self.current-frame;
        return True
            if $frame.pad{$name} :exists;
    }

    method register-subhandler {
        self.declare-var("--RETURN-TO--");
        self.put-var("--RETURN-TO--", $.current-frame);
    }

    method load-builtins {
        # XXX: should be in a hash
        self.declare-var("say");
        self.put-var("say", Val::Sub::Builtin.new(-> $arg { self.output.say(~$arg) }));

        self.declare-var("type");
        self.put-var("type", Val::Sub::Builtin.new(sub ($arg) { return 'Sub' if $arg ~~ Val::Sub; $arg.^name.substr('Val::'.chars) }));

        self.declare-var("abs");
        self.put-var("abs", Val::Sub::Builtin.new(-> $arg { $arg.value.Int.abs }));

        self.declare-var("min");
        self.put-var("min", Val::Sub::Builtin.new(-> $a, $b { min($a.value, $b.value) }));

        self.declare-var("max");
        self.put-var("max", Val::Sub::Builtin.new(-> $a, $b { max($a.value, $b.value) }));

        self.declare-var("chr");
        self.put-var("chr", Val::Sub::Builtin.new(-> $arg { $arg.value.chr }));
    }

    method sigbind($type, $c, @args) {
        die "$type with {$c.parameters.parameters.elems} parameters "       # XXX: make this into an X::
            ~ "called with {@args.elems} arguments"
            unless $c.parameters.parameters == @args;
        self.enter($c);
        for $c.parameters.parameters Z @args -> $param, $arg {
            my $name = $param.name;
            self.declare-var($name);
            self.put-var($name, $arg);
        }
    }

    multi method call(Val::Block $c, @args) {
        self.sigbind("Block", $c, @args);
        $c.statements.run(self);
        self.leave;
        return Val::None.new;
    }

    multi method call(Val::Sub $c, @args) {
        self.sigbind("Sub", $c, @args);
        self.register-subhandler;
        my $frame = self.current-frame;
        $c.statements.run(self);
        self.leave;
        CATCH {
            when X::Control::Return {
                die $_   # keep unrolling the interpreter's stack until we're there
                    unless .frame === $frame;
                self.unroll-to($frame);
                self.leave;
                return .value;
            }
        }
        return Val::None.new;
    }

    multi method call(Val::Sub::Builtin $c, @args) {
        my $result = $c.code.(|@args);
        return $result if $result;
        return Val::None.new;
    }
}

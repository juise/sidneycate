.PHONY: all deps compile rel run clean

REBAR=$(shell which rebar || echo ./rebar)


all: $(REBAR) deps compile

deps:
		$(REBAR) get-deps

compile:
		$(REBAR) compile

rel: $(REBAR) deps compile
		$(REBAR) generate

run:
		erl -pa ./ebin/ ./deps/*/ebin/ -boot start_sasl -config sys.config -sname $(name) -s sync -s sidneycate

clean:
		$(REBAR) clean
		rm -rf ./rebar
		rm -rf ./ebin
		rm -rf ./rel/sidnecycat
		rm -rf ./erl_crash.dump

# Get rebar if it doesn't exist
REBAR_URL=https://github.com/rebar/rebar/wiki/rebar

./rebar:
	erl -noinput -noshell -s inets -s ssl \
		-eval '{ok, _} = httpc:request(get, {"${REBAR_URL}", []}, [], [{stream, "${REBAR}"}])' \
		-s init stop
	chmod +x ${REBAR}

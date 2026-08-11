# Locator ergonomics — evaluate/evaluate_all/element_handle on a Locator,
# and the accessors that make `loc.frame`/`loc.selector` unnecessary.
#
# Hermetic: what matters here is that the locator's own selector and strictness
# reach the wire, which is exactly what a caller reaching into private fields
# was doing by hand before.

using Playwright: evaluate_all, element_handle, frame, selector, is_strict

@testset "locator ergonomics" begin
    @testset "evaluate on a Locator carries its selector and strictness" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#volume")

        sent = waiting_request(
            f.fake,
            () -> evaluate(loc, "(el, v) => el.value = v", 7);
            result = Dict{String,Any}("value" => Dict("n" => 7)),
        )
        @test sent["guid"] == "frame@1"
        @test sent["method"] == "evalOnSelector"
        @test sent["params"]["selector"] == "#volume"
        @test sent["params"]["expression"] == "(el, v) => el.value = v"
        @test sent["params"]["strict"] == true
        @test sent["params"]["arg"]["value"]["n"] == 7
        shutdown!(f.fake)
    end

    @testset "a non-strict Locator says so on the wire" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "input"; strict = false)
        sent = waiting_request(
            f.fake,
            () -> evaluate(loc, "el => el.value");
            result = Dict{String,Any}("value" => Dict("s" => "x")),
        )
        @test sent["params"]["strict"] == false
        shutdown!(f.fake)
    end

    @testset "evaluate returns the value through the codec, not the raw wire form" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#volume")
        task = @async evaluate(loc, "el => el.value")
        msg = next_message(f.fake)
        reply_ok(f.fake, msg["id"], Dict{String,Any}("value" => Dict("s" => "seven")))
        @test await(task) == "seven"
        shutdown!(f.fake)
    end

    @testset "evaluate_all runs against every match" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "input"; strict = false)
        sent = waiting_request(
            f.fake,
            () -> evaluate_all(loc, "els => els.length");
            result = Dict{String,Any}("value" => Dict("n" => 2)),
        )
        @test sent["method"] == "evalOnSelectorAll"
        @test sent["params"]["selector"] == "input"
        # evalOnSelectorAll has no strict parameter: "all the matches" is not
        # an ambiguity, so strictness would have nothing to decide.
        @test !haskey(sent["params"], "strict")
        shutdown!(f.fake)
    end

    @testset "element_handle resolves the locator to a handle" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#volume")
        sent = waiting_request(f.fake, () -> element_handle(loc))
        @test sent["method"] == "querySelector"
        @test sent["params"]["selector"] == "#volume"
        @test sent["params"]["strict"] == true
        shutdown!(f.fake)
    end

    @testset "the public accessors report what the locator was built with" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#volume")
        @test frame(loc) === f.frame
        @test selector(loc) == "#volume"
        @test is_strict(loc) === true

        loose = Playwright.locator(f.frame, "input"; strict = false)
        @test is_strict(loose) === false
        shutdown!(f.fake)
    end

    @testset "the accessors are exported, so no caller needs the private fields" begin
        # In miniature: everything a range-input helper once reached
        # into is now reachable through the public surface.
        for name in (:evaluate_all, :element_handle, :frame, :selector, :is_strict)
            @test name in names(Playwright)
        end
    end
end

package main

import (
	"fmt"
	"time"
)

func main() {

	later := time.Now().Add(11 * time.Second)

	ticker01, done := SetTicker(5 * time.Second)
	//ticker02, tickerChan02 := SetTicker(5000 * time.Millisecond)
	//ticker03, tickerChan03 := SetTicker(7500 * time.Millisecond)
	//ticker04, tickerChan04 := SetTicker(8200 * time.Millisecond)

	for i := 0; i <= 60; i++ {
		//		fmt.Println(<-ticker01.C)
		time.Sleep(1 * time.Second)
		value := <-ticker01.C
		fmt.Printf("Value %v\n", value)
		fmt.Printf("Later %v\n", later)
		fmt.Println("Value After Later:", value.After(later))
		if value.After(later) {
			ticker01.Stop()
			done <- true
			break
		}
	}

}

func SetTicker(interval time.Duration) (time.Ticker, chan bool) {
	ticker := time.NewTicker(interval)
	tickerChan := make(chan bool)
	go func() {
		for {
			select {
			case <-tickerChan:
				return
			}
		}
	}()
	return *ticker, tickerChan
}
